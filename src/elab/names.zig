//! Hierarchical names: an instance path and a local name → the flat, injective
//! name the lowered design uses; module and paramset lookup; access-function
//! respelling across a port join; constant folding of instance bounds.
//! LRM §3.6.1.2, §3.6.5, §4.4, §6.2.2, §6.3.6, §6.4, §6.5.2.1, §6.6.1, §6.6.2, §6.6.3, §6.7, §7.4,
//! E.3.2, E.3.3.

const std = @import("std");
const elaborate = @import("elaborate.zig");
const Flatten = elaborate.Flatten;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const discipline = @import("discipline_rules.zig");
const Lexer = @import("frontend").Lexer;
const Error = elaborate.Error;
const Unit = Flatten.Unit;

/// §6.7 a hierarchical expression's path in the flattened namespace. Shared
/// by lowering and the pre-fold §3.4.7 alias-use check. Port joins are applied
/// by the caller because they are design connectivity, not name spelling.
pub fn flatReference(file: *const Ast.SourceFile, arena: std.mem.Allocator, module: ?*const Ast.ModuleDecl, e: Ast.ExprId) std.mem.Allocator.Error![]const u8 {
    var parts = file.exprs.nameParts(e);
    // §6.2.1 the `$root` prefix: "used to unambiguously refer to a top-level
    // instance or to an instance path starting from the root of the instantiation
    // tree", against a plain path, where "the ambiguity is resolved by giving
    // priority to the local scope". Elaboration's flat namespace IS rooted — a
    // name with no path prefix is a name of the top, so `$root.` is dropped.
    // The segment after it names a top-level instance (§6.7's
    // `$root.mymodule.u1`), and a flattened design's one top-level instance is
    // the device itself, so the top module's name drops with it.
    //
    // Not done in `Elaborate`'s clone: the top module's body is never cloned,
    // so the rule would only reach children. Here it applies to every unit.
    if (parts.len > 1 and file.strings.eql(parts[0], "$root")) parts = parts[1..];
    // The top module's own name, with or without `$root`: IEEE 1364 §12.6's
    // upward name referencing, which §6.7.1's last paragraph adopts, lets a
    // path open with the name of a module above the reference; §5.5.5's
    // example reads `V(top.a1.b)` from inside `b1`. The flattened namespace is
    // rooted at the top, so its name drops. A local of the same name wins
    // (§6.2.1 "priority to the local scope"): cloning has already renamed
    // part 0 of a child's local path, and the top's own instances are
    // checked here.
    if (parts.len > 1) if (module) |m| if (parts[0] == m.name and for (m.instances) |inst| {
        if (inst.name == parts[0]) break false;
    } else true) {
        parts = parts[1..];
    };
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0) try out.append(arena, elaborate.sep);
        try out.appendSlice(arena, file.str(p));
    }
    return out.toOwnedSlice(arena);
}

/// §6.6.2: "If the generate block selected for instantiation is not named,
/// it still creates a scope; but the declarations within it cannot be
/// referenced using hierarchical names other than from within the hierarchy
/// instantiated by the generate block itself" (§6.6.1 says the same of a
/// loop), and §6.6.3: it "has no name that can be used in a hierarchical
/// name". Appends to `out` the flat prefix of each unnamed generate block of
/// `m` instantiated at `path`: `path ++ "genblk1."`, inside named blocks too,
/// and `path ++ "genblk4["` for an unnamed loop block, whose copies are
/// `genblk4[i]`. A hierarchical name spelled into one of them from outside
/// it is E0998 (`Lower`'s `refuseUnnamedGen`).
///
/// ponytail: blocks nested inside a loop's block are not listed; their
/// prefixes carry the iteration index. The upgrade is `loopInstances`'s walk.
pub fn unnamedGenScopes(file: *const Ast.SourceFile, arena: std.mem.Allocator, m: *const Ast.ModuleDecl, path: []const u8, out: *std.ArrayList([]const u8)) std.mem.Allocator.Error!void {
    for (m.analog) |blk| try genScopesIn(file, arena, blk.body, path, out);
}

fn genScopesIn(file: *const Ast.SourceFile, arena: std.mem.Allocator, id: Ast.StmtId, prefix: []const u8, out: *std.ArrayList([]const u8)) std.mem.Allocator.Error!void {
    if (id == .none) return;
    switch (file.stmt(id)) {
        .block => |b| {
            var inner = prefix;
            if (b.gen_name != .none) {
                inner = try arena.print("{s}{s}{c}", .{ prefix, file.str(b.gen_name), elaborate.sep });
                if (b.name == .none) try out.append(arena, inner);
            }
            for (b.body) |st| try genScopesIn(file, arena, st, inner, out);
        },
        .if_stmt => |st| if (st.is_generate) {
            try genScopesIn(file, arena, st.then_s, prefix, out);
            try genScopesIn(file, arena, st.else_s, prefix, out);
        },
        .case_stmt => |st| for (st.arms) |a| try genScopesIn(file, arena, a.body, prefix, out),
        .for_stmt => |st| if (st.body != .none and file.stmt(st.body) == .block) {
            const b = file.stmt(st.body).block;
            if (b.gen_name != .none and b.name == .none)
                try out.append(arena, try arena.print("{s}{s}[", .{ prefix, file.str(b.gen_name) }));
        },
        else => {}, // else: no other statement holds a generate block
    }
}

/// Whether `name` is the §6.6.3 external name of an unnamed generate block
/// at `m`'s own scope (not nested in a named block): the first part of a
/// hierarchical name written in `m` that would open it (§6.6.2, E0998).
pub fn namesUnnamedGen(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (m.analog) |blk| if (unnamedGenIn(file, blk.body, name)) return true;
    return false;
}

fn unnamedGenIn(file: *const Ast.SourceFile, id: Ast.StmtId, name: Ast.StrId) bool {
    if (id == .none) return false;
    switch (file.stmt(id)) {
        // A generate scope's own blocks are a level further down.
        .block => |b| {
            if (b.gen_name != .none) return b.name == .none and b.gen_name == name;
            for (b.body) |st| if (unnamedGenIn(file, st, name)) return true;
        },
        .if_stmt => |st| if (st.is_generate) return unnamedGenIn(file, st.then_s, name) or unnamedGenIn(file, st.else_s, name),
        .case_stmt => |st| for (st.arms) |a| if (unnamedGenIn(file, a.body, name)) return true,
        else => {}, // else: no other statement holds a generate block at this scope
    }
    return false;
}

// ---- names ------------------------------------------------------------

/// Returns `path ++ local`, interned. The flat name is the §6.7 path, so the
/// path table (`Design.names`) needs no row for it.
pub fn join(self: *Flatten, path: []const u8, local: Ast.StrId) Error!Ast.StrId {
    const s = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(local) });
    return self.ctx.file.intern(self.ctx.arena, s);
}

/// A flat name `path ++ local`, not yet joined: the key shape of
/// `Flatten.defparams` and `Flatten.ooc`, probed with `getAdapted` and
/// `Context` so a lookup allocates nothing.
pub const PathKey = struct {
    // A probe used to print the joined key into the compilation arena and
    // drop it, once per parameter, alias, port and net of every instance.
    path: []const u8,
    local: []const u8,

    /// `std.hash_map.StringContext` over the joined bytes: Wyhash streamed
    /// over the two halves equals Wyhash of their concatenation, so the probe
    /// lands in the bucket the stored `path ++ local` key hashed to.
    pub const Context = struct {
        /// Returns `StringContext.hash(k.path ++ k.local)`.
        pub fn hash(_: Context, k: PathKey) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(k.path);
            h.update(k.local);
            return h.final();
        }
        /// Returns whether `stored` is exactly `k.path ++ k.local`.
        pub fn eql(_: Context, k: PathKey, stored: []const u8) bool {
            return stored.len == k.path.len + k.local.len and
                std.mem.startsWith(u8, stored, k.path) and
                std.mem.endsWith(u8, stored, k.local);
        }
    };
};

/// Binds `local` to its flat name `path ++ local` in `unit`'s rename map,
/// unless it is already bound (a port joined to the parent's net).
pub fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) Error!void {
    // A port already bound to the parent's net keeps that binding: `inout p;
    // electrical p;` leaves a NetDecl behind for the same name, and rewriting
    // it here would disconnect the port.
    if (unit.rename.contains(local)) return;
    try unit.rename.put(self.ctx.arena, local, try join(self, path, local));
}

/// Returns the flat spelling of a name in the unit being cloned. A name with
/// no entry is not the unit's (a block-local, a function formal, or a §3.6.5
/// implicit net) and keeps its own spelling.
pub fn flat(self: *Flatten, local: Ast.StrId) Ast.StrId {
    return self.unit.rename.get(local) orelse local;
}

/// Reports an instance whose module name declares nothing: E0904, or E0952
/// when the SPICE netlist has a `.MODEL` of that name whose type is a
/// primitive VerA does not support (E.1.2: "a particular SPICE netlist can
/// reference a primitive which is unsupported"). The name matches the card
/// as E.2.1 matches netlist names, regardless of case.
pub fn unknownModule(self: *Flatten, inst: *const Ast.Instance) Error!void {
    const want = self.ctx.file.str(inst.module);
    for (self.ctx.file.netlist_unsupported) |card| {
        const space = std.mem.findScalar(u8, card, ' ').?; // `name type`
        if (!std.ascii.eqlIgnoreCase(card[0..space], want)) continue;
        return self.err(inst.main_tok, .E0952, "`{s}` is a SPICE `.MODEL` of type `{s}`, a primitive Table E.1 and VerA do not provide", .{ want, card[space + 1 ..] });
    }
    try self.err(inst.main_tok, .E0904, "`{s}`", .{want});
}

/// Returns the net a port connection names, or null when it is not a plain
/// identifier. §6.2.2 allows an expression; VerA takes a scalar net
/// reference, which a topology join can express without a new node.
pub fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
    if (e == .none) return null;
    if (self.ctx.file.exprs.tag(e) != .ident) return null;
    return self.ctx.file.exprs.strOf(e);
}

/// Returns the module `name` denotes, or null. Lookup order: user modules,
/// the LAST of several same-named ones (IEEE 1364-2005 §13.2.1.1, see
/// `warnRedefinedModules`), then the shipped Annex E prelude, since E.3.3 selects "a module or
/// paramset defined in the Verilog-AMS ... in favor of a SPICE primitive,
/// model, or subcircuit using exactly the same name". Last, E.2.1: "if no
/// exact match is found, the mixed-case name shall match the same name
/// defined within SPICE regardless of the case", over the netlist-derived
/// modules only (already lower-cased).
///
/// An exact paramset match returns null so the caller selects that paramset
/// before considering any SPICE definition. Declaration collisions with a
/// netlist are diagnosed by `warnSpiceShadows`; the optional warning for a
/// Table E.1 primitive alone is not issued. Two SPICE objects of the same
/// name resolve primitive-first; Annex E does not order them.
pub fn findModule(self: *Flatten, name: Ast.StrId) ?*const Ast.ModuleDecl {
    const user = self.ctx.file.userModules();
    var i = user.len;
    while (i > 0) {
        i -= 1;
        if (user[i].name == name) return &user[i];
    }
    for (self.ctx.file.paramsets) |ps| if (ps.name == name) return null;
    for (self.ctx.file.modules[0..self.ctx.file.builtin_modules]) |*m| {
        if (m.name == name) return m;
    }
    const want = self.ctx.file.str(name);
    for (self.ctx.file.netlistModules()) |*m| {
        if (std.ascii.eqlIgnoreCase(self.ctx.file.str(m.name), want)) return m;
    }
    return null;
}

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

/// IEEE 1364-2005 §13.2.1.1: "If multiple cells with the same name map to
/// the same library, then the LAST cell encountered shall be written to the
/// library" and "a warning message shall be issued" (W1152). §4.11's ban on
/// reusing a module name predates libraries; the digital binder reads it the
/// same way (`lib/sim/digital/bind.zig` `libraries`), so one design
/// elaborates alike in both engines. `findModule` and `pickTop` take the
/// last definition.
pub fn warnRedefinedModules(self: *Flatten) Error!void {
    const user = self.ctx.file.userModules();
    for (user, 0..) |m, i| for (user[i + 1 ..]) |later| {
        if (later.name != m.name) continue;
        try self.ctx.bag.add(.lower, .W1152, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, later.main_tok), "`{s}` is defined again; this later definition is the module", .{self.ctx.file.str(m.name)});
        break;
    };
}

/// E.3.3 requires a warning for a same-named HDL declaration and a SPICE
/// model/subcircuit. Check definitions once, independently of the repeated
/// lookups used for ports, connect planning and parameter selection. Netlist
/// names have E.2.1's canonical lowercase spelling; a differently cased HDL
/// declaration leaves case-insensitive fallback available and does not warn.
pub fn warnSpiceShadows(self: *Flatten) Error!void {
    const file = self.ctx.file;
    for (file.netlistModules()) |spice| {
        for (file.userModules()) |m| if (m.name == spice.name)
            try spiceShadowWarning(self, m.name, m.main_tok, "module");
        for (file.paramsets) |ps| if (ps.name == spice.name)
            try spiceShadowWarning(self, ps.name, ps.main_tok, "paramset");
    }
}

fn spiceShadowWarning(self: *Flatten, name: Ast.StrId, tok: u32, kind: []const u8) Error!void {
    try self.ctx.bag.add(.lower, .W0951, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), "{s} `{s}` is used instead of the SPICE model or subcircuit when this name is instantiated", .{ kind, self.ctx.file.str(name) });
}

/// §6.4: "The second identifier is usually the name of a module with which
/// the paramset is associated. The second identifier may instead be the name
/// of a second paramset. A chain of paramsets may be defined, but the last
/// paramset in the chain shall reference a module."
///
/// Appends the chain's links to `out`, near (the one the instance named) to
/// far. Returns false after reporting E0904 when a link names neither a
/// module nor a paramset, or the chain is a cycle.
///
/// The chain is walked by name and the first declaration of that name wins.
/// §6.4.2's selection rules are written for "every instance that references
/// that name", and a chain link is not an instance, so an overloaded inner
/// link has no instance context to select against.
pub fn paramsetChain(
    self: *Flatten,
    near: *const Ast.ParamsetDecl,
    out: *std.ArrayList(*const Ast.ParamsetDecl),
) Error!bool {
    // Every link is a distinct paramset (a repeat is the cycle refused below).
    try out.ensureUnusedCapacity(self.ctx.arena, self.ctx.file.paramsets.len + 1);
    var link = near;
    while (true) {
        out.appendAssumeCapacity(link);
        if (findModule(self, link.target) != null) return true;
        const next = for (self.ctx.file.paramsets) |*p| {
            if (p.name == link.target) break p;
        } else {
            try self.err(link.main_tok, .E0904, "`{s}`, the module this paramset specializes", .{
                self.ctx.file.str(link.target),
            });
            return false;
        };
        // A chain that closes on itself never reaches a module, so §6.4's
        // "the last paramset in the chain shall reference a module" is
        // violated by the cycle itself.
        for (out.items) |seen| if (seen == next) {
            try self.err(next.main_tok, .E0904, "`{s}`: the paramset chain is a cycle and never reaches a module", .{
                self.ctx.file.str(next.name),
            });
            return false;
        };
        link = next;
    }
}

/// The module at the end of `ps`'s chain, or `null` after an E0904.
pub fn chainEnd(self: *Flatten, ps: *const Ast.ParamsetDecl) Error!?*const Ast.ModuleDecl {
    var chain: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    if (!try paramsetChain(self, ps, &chain)) return null;
    return findModule(self, chain.items[chain.items.len - 1].target).?;
}

/// Returns whether `m` is one of the shipped Table E.1 primitives (Annex E).
/// Identity, not name: a user module called `resistor` shadows the primitive
/// (E.3.3, see `findModule`) and must not get E.3.2's treatment: E.3.2.1's
/// port_discipline "shall only apply to analog primitives ... for other
/// modules as well as the ports of all other modules it shall be ignored".
///
/// Table E.1's own rows only: a module synthesized from a netlist `.MODEL`
/// card is a wrapper around a primitive, not a primitive, and its body is one
/// instantiation with no access function of its own to substitute.
pub fn isPrimitive(self: *Flatten, m: *const Ast.ModuleDecl) bool {
    // Table E.1's rows are one contiguous run of `modules`, so identity is an
    // address range test, not a scan.
    const rows = self.ctx.file.tablePrimitives();
    const at = @intFromPtr(m);
    return at >= @intFromPtr(rows.ptr) and at < @intFromPtr(rows.ptr + rows.len);
}

/// Checks every E.3.2.1 `port_discipline` attribute on `inst` (E0358).
/// "The value shall be of type string and the
/// value must be a valid discipline of domain continuous. This attribute
/// shall only apply to analog primitives or the ports of analog primitives;
/// for other modules as well as the ports of all other modules it shall be
/// ignored." So it is judged here, on an instance `isPrimitive` answered
/// yes for, and nowhere else.
///
/// `module.attrs` holds every attr_spec of the instantiating module without
/// its target (`Parser.skipAttributes`), so the target is recovered from the
/// token stream: the first token after the attribute-instance run an
/// attr_spec sits in is the item it decorates, and that item is this
/// instantiation (its module identifier, with no `;` before the instance
/// name) or one of its port connections.
pub fn checkPortDiscipline(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance) Error!void {
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.ctx.file.str(a.name), "port_discipline")) continue;
        if (!decorates(self, decoratedTok(self, a.main_tok), inst)) continue;
        // §2.9: a valueless attr_spec has the value 1, which is not a string.
        const c = if (a.value == .none)
            constfold.Const{ .int = 1 }
        else
            // Not constant: lowering's E0357 (§2.9) owns that answer.
            constfold.fold(self.ctx.file, a.value, ParamEnv{ .self = self, .local = true }) orelse continue;
        const want = switch (c) {
            .str => |sv| sv,
            else => {
                try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline requires a string naming a continuous discipline", .{});
                continue;
            },
        };
        const d = discipline.declOf(self.ctx.file, self.ctx.file.strings.find(want) orelse .none) orelse {
            try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline names an undeclared discipline `{s}`", .{want});
            continue;
        };
        if (discipline.domainOf(d) != .continuous)
            try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline requires a continuous discipline; `{s}` is not one", .{want});
    }
}

/// E.3.2's first source for one port of a primitive instance: the
/// `port_discipline` on its connection, else the one on the instance ("It
/// shall only apply to either the analog primitive itself or the port to which
/// it is attached"; E.3.2.1's `motor1` example overrides the instance's per
/// port). Null when neither carries a valid one; `checkPortDiscipline`
/// reports an invalid one.
pub fn portDisciplineAttr(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance, conn: Ast.PortConn) ?Ast.StrId {
    var on_inst: ?Ast.StrId = null;
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.ctx.file.str(a.name), "port_discipline")) continue;
        const t = decoratedTok(self, a.main_tok);
        if (!decorates(self, t, inst)) continue;
        if (a.value == .none) continue;
        const c = constfold.fold(self.ctx.file, a.value, ParamEnv{ .self = self, .local = true }) orelse continue;
        if (c != .str) continue;
        const name = self.ctx.file.strings.find(c.str) orelse continue;
        const d = discipline.declOf(self.ctx.file, name) orelse continue;
        if (discipline.domainOf(d) != .continuous) continue;
        if (t == conn.main_tok) return name;
        for (inst.ports) |p| {
            if (p.main_tok == t) break;
        } else on_inst = name;
    }
    return on_inst;
}

/// The source text of token `t`.
fn tokText(self: *Flatten, t: u32) []const u8 {
    const sp = Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, t);
    return self.ctx.src[sp.start..sp.end];
}

/// The first token after the run of `(* ... *)` instances that token `t`
/// (an attr_name) is inside. §2.9 forbids nesting, so the first `*)` closes.
fn decoratedTok(self: *Flatten, t: u32) u32 {
    const n: u32 = @intCast(self.ctx.tok_starts.len);
    var i = t;
    while (i < n) {
        while (i < n and !std.mem.eql(u8, tokText(self, i), "*)")) i += 1;
        i += 1;
        if (i >= n or !std.mem.eql(u8, tokText(self, i), "(*")) return i;
    }
    return i;
}

/// Is token `t` the start of `inst`'s instantiation or of one of its port
/// connections? A.4.1 attaches `{ attribute_instance }` to both.
fn decorates(self: *Flatten, t: u32, inst: *const Ast.Instance) bool {
    for (inst.ports) |c| if (c.main_tok == t) return true;
    if (t >= inst.main_tok or !std.mem.eql(u8, tokText(self, t), self.ctx.file.str(inst.module))) return false;
    // `resistor r1(a, b), r2(c, d);` shares one attribute list; a `;` between
    // means `t` began an earlier statement.
    var i = t + 1;
    while (i < inst.main_tok) : (i += 1) if (std.mem.eql(u8, tokText(self, i), ";")) return false;
    return true;
}

/// Returns the access function a shipped primitive's `V` or `I` means on the
/// net its port was connected to (E.3.2).
///
/// Table E.1's Behavior column writes V and I for every row, but E.3.2 lets a
/// primitive "be used in any design, including mixed disciplines" (E.3.2.1's
/// `vcvs` with a `rotational_omega` control pair). So V is the port pair's
/// potential and I its flow, spelled with the §3.6.1.2 access function of the
/// discipline the net resolved to. The discipline is read from the net,
/// where `walkInstances` binds E.3.2's three sources in order.
///
/// Limits: an unconnected primitive port carrying the attribute keeps the
/// prelude's `electrical`, and a primitive cloned before a later level
/// resolves its net keeps V/I. Applies to prelude bodies only
/// (`Unit.primitive`); a user module's `V` means V.
pub fn primitiveAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId) Ast.StrId {
    const which: Ast.PotentialOrFlow = blk: {
        const a_ = self.ctx.file.str(access);
        if (std.mem.eql(u8, a_, "V")) break :blk .potential;
        if (std.mem.eql(u8, a_, "I")) break :blk .flow;
        return access; // not one of the table's two spellings
    };
    const name = netRefName(self, net) orelse return access;
    const disc = self.disc_of.get(name) orelse .none;
    if (disc == .none) return access; // §3.6.5 implicit, or resolved later
    return discipline.accessOf(self.ctx.file, disc, which) orelse access;
}

/// §4.4: "The access function name shall match the discipline declaration
/// for the nets, ports, or branch given in the argument expression list." In a
/// child, that declaration is the child's own: §7.4 resolves disciplines only
/// for nets "whose discipline is undeclared", and §6.5.8 lets one node carry
/// several continuous disciplines. So an access on a bound port is judged
/// against the port's local discipline (`Unit.port_disc`), E0501 here since
/// after the join lowering sees only the parent's net, and then respelled as
/// the same half of the net it was joined to, the rewrite `primitiveAccess`
/// makes for Table E.1's V and I. `net` is the terminal as the child wrote it,
/// `flat_net` the same terminal cloned.
///
/// When the joined net's discipline binds no nature for that half (§3.11.1's
/// natureless or domainless parent, compatible with the child's), there is no
/// spelling to respell to: the access keeps the child's name and is recorded
/// `local_only`, so lowering does not judge it again against the net
/// (`Design.local_accesses`).
///
/// ponytail: the respelling uses the net's discipline as known at the join;
/// a §7.7.2 `resolveto` re-decided after the walk (`resolveMultiCandidates`)
/// is not seen, the same ceiling `primitiveAccess` and `mfactorScale` have.
pub fn localAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, flat_net: Ast.ExprId, tok: u32) Error!LocalAccess {
    const file = self.ctx.file;
    const keep: LocalAccess = .{ .name = access };
    const local = self.unit.port_disc.get(netRefName(self, net) orelse return keep) orelse return keep;
    const disc = self.disc_of.get(netRefName(self, flat_net) orelse return keep) orelse return keep;
    if (disc == local) return keep;
    // §5.5.1 the generic spellings name a half on every discipline.
    const a = file.str(access);
    if (std.mem.eql(u8, a, "potential") or std.mem.eql(u8, a, "flow")) return keep;
    const half: Ast.PotentialOrFlow = if (discipline.accessOf(file, local, .potential) == access)
        .potential
    else if (discipline.accessOf(file, local, .flow) == access)
        .flow
    else {
        try self.err(tok, .E0501, "`{s}` is not an access function of `{s}`, which this module declares `{s}`", .{
            a, file.str(file.exprs.strOf(net)), file.str(local),
        });
        return keep;
    };
    const name = discipline.accessOf(file, disc, half) orelse return .{ .name = access, .local_only = true };
    return .{ .name = name };
}

/// §6.5.2.1 "If the type of a port is not declared, the port can only be
/// used in a structural description. (It can be passed to instances of
/// modules, but cannot be accessed in a behavioral description.)" Reports
/// E0337 when `net`, a terminal of the access `access` as the child wrote
/// it, is a BOUND port of this unit with no local discipline (#74). After
/// the join lowering sees only the parent's net, which discipline
/// resolution (§7.4) may have given a discipline, so the child's own
/// declaration is judged here. An unconnected port is an internal net with
/// its own (missing) discipline, which lowering's `checkAccessMatch`
/// reports; Table E.1 primitives are `primitiveAccess`'s, not this.
///
/// ponytail: a plain identifier only; a vector port element (`c[0]`) or a
/// named branch over the port is still judged by the joined net.
pub fn checkTypedPort(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, tok: u32) Error!void {
    std.debug.assert(!self.unit.primitive);
    const name = netRefName(self, net) orelse return;
    if (!(self.unit.connected.get(name) orelse return)) return;
    if (self.unit.port_disc.contains(name)) return;
    const file = self.ctx.file;
    try self.err(tok, .E0337, "`{s}` is a port of `{s}` with no discipline, so `{s}` names nothing on it (§6.5.2.1: an untyped port is structural only); declare one, e.g. `electrical {s};`", .{
        file.str(name), if (self.unit.module) |m| file.str(m.name) else self.unit.path, file.str(access), file.str(name),
    });
}

/// `localAccess`'s answer: the spelling, and whether only the child's
/// declaration can judge it.
const LocalAccess = struct { name: Ast.StrId, local_only: bool = false };

/// Returns `value` multiplied or divided (`op`) by the unit's running
/// `$mfactor` product when `access` is the flow access of `net`'s discipline,
/// else null (§6.3.6's two automatic scaling rules).
///
///     "All contributions to a branch flow quantity in the analog block
///      shall be multiplied by $mfactor. The value returned by any branch
///      flow probe in the analog block ... shall be divided by $mfactor."
///
/// A flattened child's $mfactor copies exist only in its own equations, so
/// the scaling is source arithmetic. The top's $mfactor stays with the host
/// (Table 9-29's 1.0; `unit.hier.get(.mfactor)` is `.none` there and nothing fires).
///
/// A §3.12 named branch (`I(br)`, `I(br[k])`) answers through its first
/// terminal's discipline (`accessNet`). Rules 3 and 4 (noise power) are
/// `mfactorNoise`'s.
pub fn mfactorScale(
    self: *Flatten,
    value: Ast.ExprId,
    access: Ast.StrId,
    net: Ast.ExprId,
    op: Ast.BinaryOp,
    tok: u32,
) Error!?Ast.ExprId {
    if (self.unit.hier.get(.mfactor) == .none) return null;
    const name = netRefName(self, accessNet(self, net)) orelse return null;
    const disc = self.disc_of.get(name) orelse return null;
    const flow = discipline.accessOf(self.ctx.file, disc, .flow) orelse return null;
    if (flow != access) return null; // a potential
    return try self.ctx.file.exprs.add(self.ctx.arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = value,
        .rhs = self.unit.hier.get(.mfactor),
        .extra = @backingInt(op),
    });
}

/// The net whose discipline answers for an access to `net` (flat names): `net`
/// itself, or the first terminal of the §3.12 named branch `net` names (an
/// element of a branch array included). A unit's branches are appended to
/// `branches` before its analog blocks are cloned (`instance.zig`).
///
/// ponytail: a linear scan per flow access of a scaled instance; a flat name
/// → branch map if a design with many branches makes it show.
fn accessNet(self: *Flatten, net: Ast.ExprId) Ast.ExprId {
    const x = &self.ctx.file.exprs;
    var base = net;
    if (base != .none and x.tag(base) == .index) base = x.lhs(base);
    if (base == .none or x.tag(base) != .ident) return net;
    for (self.branches.items) |b| if (b.name == x.strOf(base)) return b.hi;
    return net;
}

/// Returns noise call `call` scaled for §6.3.6's rules 3 and 4: "Contributions
/// to a branch flow quantity using the noise functions (white_noise,
/// flicker_noise, noise_table) shall have the noise power multiplied by
/// $mfactor", and a potential's "divided by $mfactor". A noise function's
/// value is an amplitude, so the call becomes `call / $mfactor ** 0.5`: on a
/// flow, rule 1's factor (`mfactorScale`) makes the amplitude sqrt(m) and the
/// power m; a potential, which rule 1 leaves alone, gets power 1/m. §4.6.3's
/// `ac_stim` is a stimulus, not noise, and keeps rule 1 alone. The top's
/// $mfactor stays with the host, as in `mfactorScale`.
pub fn mfactorNoise(self: *Flatten, call: Ast.ExprId) Error!Ast.ExprId {
    const m = self.unit.hier.get(.mfactor);
    if (m == .none) return call;
    const x = &self.ctx.file.exprs;
    if (std.mem.eql(u8, self.ctx.file.str(x.strOf(call)), "ac_stim")) return call;
    const tok = x.mainTok(call);
    const arena = self.ctx.arena;
    const root = try x.add(arena, .{ .tag = .binary, .main_tok = tok, .lhs = m, .rhs = try x.addReal(arena, tok, 0.5), .extra = @backingInt(Ast.BinaryOp.pow) });
    return x.add(arena, .{ .tag = .binary, .main_tok = tok, .lhs = call, .rhs = root, .extra = @backingInt(Ast.BinaryOp.div) });
}

/// Folds a §6.2.2 instance array bound, written in the current unit's local
/// names, to an integer; null when it does not fold or is real. A bound may
/// read a parameter (§3.4), with this instance's overrides applied.
pub fn constInt(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = true }) orelse return null;
    return if (c == .int) c.int else null;
}

/// `constInt` for an expression already in the flat namespace (a cloned
/// declaration's range, say), so no name is renamed.
pub fn constIntFlat(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = false }) orelse return null;
    return if (c == .int) c.int else null;
}

/// §6.6.2 whether the generate scheme `gate` (flat names, `.none` for an
/// instance outside any scheme) brings its instance into existence: it folds
/// true. One that does not fold is not known to.
pub fn gateHolds(self: *Flatten, gate: Ast.ExprId) bool {
    if (gate == .none) return true;
    const c = constValue(self, gate, false, null) orelse return false;
    return c.isTrue();
}

/// §6.4.2 folds an override in its source namespace. When `reads` is supplied,
/// it records which flattened parameter values an overload choice used, for
/// the same host shape check that protects §6.6 generate selection.
pub fn constValue(self: *Flatten, e: Ast.ExprId, local: bool, reads: ?[]bool) ?constfold.Const {
    return constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = local, .reads = reads });
}

/// One `Flatten.param_values` row: a flat parameter's folded value, once
/// one is known. A default that does not fold is not remembered, since a
/// parameter appended later may make it fold.
pub const ParamValue = union(enum) { unknown, folding, done: constfold.Const };

/// Grows `Flatten.param_values` to one row per flat parameter; run after
/// every append to `Flatten.params`.
pub fn syncParamValues(self: *Flatten) Error!void {
    const have = self.param_values.items.len;
    std.debug.assert(have <= self.params.items.len);
    try self.param_values.appendNTimes(self.ctx.arena, .unknown, self.params.items.len - have);
}

/// Flat parameter `i`'s folded value, cached. The parameters before `i` are
/// folded first, in order, so a default's nested folds find their reads
/// cached: the stack holds one default's depth, not a chain of them (a
/// chain of `links` defaults each `d` deep needed `links * d` levels on a
/// stack the parse reserved for `d`, and overflowed it). A parameter met
/// again while its own default is folding is a cycle and declines.
fn paramValue(self: *Flatten, i: usize, depth: u8) ?constfold.Const {
    const rows = self.param_values.items;
    std.debug.assert(rows.len == self.params.items.len); // `syncParamValues`
    switch (rows[i]) {
        .done => |v| return v,
        .folding => return null,
        .unknown => {},
    }
    while (self.param_warm < i) {
        const j = self.param_warm;
        self.param_warm += 1;
        _ = paramValue(self, j, depth);
    }
    rows[i] = .folding;
    const v = (ParamEnv{ .self = self, .local = false, .depth = depth }).param(i);
    rows[i] = if (v) |c| .{ .done = c } else .unknown;
    return v;
}

/// `constfold.fold`'s identifiers, answered from the parameters flattened so
/// far. The bound is written in the instantiating module's local names, while
/// every value in `self.params` is already flat, so only the first lookup
/// renames. A scalar parameter only; anything else declines.
const ParamEnv = struct {
    self: *Flatten,
    local: bool,
    depth: u8 = 0,
    reads: ?[]bool = null,

    /// Resolves an identifier to a flattened scalar parameter's folded value.
    /// Asserts that `reads`, when given, has one flag per flattened parameter.
    pub fn leaf(env: ParamEnv, e: Ast.ExprId) ?constfold.Const {
        const self = env.self;
        // `matchingParamsets` sizes it so, and zips it with `params` after.
        if (env.reads) |reads| std.debug.assert(reads.len == self.params.items.len);
        const ex = &self.ctx.file.exprs;
        // ponytail: a depth cap, not cycle detection; a cyclic default is
        // lowering's diagnostic, this only has to terminate.
        if (ex.tag(e) != .ident or env.depth > 32) return null;
        const name = if (env.local) flat(self, ex.strOf(e)) else ex.strOf(e);
        for (self.params.items, 0..) |p, i| if (p.name == name and p.dims.len == 0) {
            // ponytail: a fold that records `reads` (§6.4.2 overload choice)
            // is not cached, so its chain of defaults still nests on the
            // stack; the upgrade is caching each parameter's read set.
            if (env.reads) |reads| {
                reads[i] = true;
                return env.param(i);
            }
            return paramValue(self, i, env.depth);
        };
        return null;
    }

    /// Flat parameter `i`'s value: a `--param` card value, else its default
    /// folded with the parameters before it.
    fn param(env: ParamEnv, i: usize) ?constfold.Const {
        const self = env.self;
        const p = self.params.items[i];
        if (!p.is_local and p.ty != .string) for (self.ctx.param_overrides) |o| {
            if (!std.mem.eql(u8, o.name, self.ctx.file.str(p.name)) or std.math.isNan(o.value)) continue;
            // The replaced default supplies an inferred TYPE only. Its
            // former value dependencies cannot change this card binding
            // and must not freeze unrelated host fields as shape inputs.
            const declared = if (p.ty == .unspecified)
                constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1 })
            else
                null;
            return constfold.parameterCardValue(p.ty, declared, o.value);
        };
        const declared = constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1, .reads = env.reads }) orelse return null;
        return constfold.parameterValue(p.ty, declared);
    }

    /// Leaves operand signedness unknown.
    pub fn signed(_: ParamEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    /// Leaves a parameter's width unknown.
    pub fn width(_: ParamEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");

test PathKey {
    // Oracle: the hash a stored `path ++ local` key got, `StringContext`'s.
    // Every split of strings around Wyhash's 48-byte block boundary must
    // land in that bucket, the empty halves included.
    var buf: [97]u8 = undefined;
    for (&buf, 0..) |*c, i| c.* = @intCast('a' + i % 26);
    for ([_]usize{ 0, 1, 47, 48, 49, 96, 97 }) |len| {
        const whole = buf[0..len];
        const want = std.hash_map.hashString(whole);
        for (0..len + 1) |cut| {
            const k: PathKey = .{ .path = whole[0..cut], .local = whole[cut..] };
            try std.testing.expectEqual(want, PathKey.Context.hash(.{}, k));
            try std.testing.expect(PathKey.Context.eql(.{}, k, whole));
        }
    }
    // `eql` is exactly the joined bytes, not a prefix or a same-length cousin.
    const key: PathKey = .{ .path = "u.", .local = "g" };
    try std.testing.expect(PathKey.Context.eql(.{}, key, "u.g"));
    try std.testing.expect(!PathKey.Context.eql(.{}, key, "u.gg"));
    try std.testing.expect(!PathKey.Context.eql(.{}, key, "u."));
    try std.testing.expect(!PathKey.Context.eql(.{}, key, "v.g"));
    try std.testing.expect(!PathKey.Context.eql(.{}, key, "u.h"));
}

/// A `.hier_ident` row over `parts`, interned into `file`.
fn hierIdent(file: *Ast.SourceFile, a: std.mem.Allocator, parts: []const []const u8) !Ast.ExprId {
    const ids = try a.alloc(Ast.StrId, parts.len);
    for (parts, ids) |p, *i| i.* = try file.intern(a, p);
    return file.exprs.add(a, .{ .tag = .hier_ident, .extra = try file.exprs.addStrList(a, ids) });
}

test flatReference {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const top = try file.intern(a, "top");
    const m: Ast.ModuleDecl = .{ .name = top, .ports = &.{} };
    const Case = struct { parts: []const []const u8, want: []const u8 };
    const cases = [_]Case{
        // §6.2.1 `$root.` and IEEE 1364 §12.6's upward `top.` both drop:
        // the flat namespace is rooted at the device.
        .{ .parts = &.{ "$root", "top", "u", "x" }, .want = "u.x" },
        .{ .parts = &.{ "top", "u", "x" }, .want = "u.x" },
        .{ .parts = &.{ "$root", "u", "x" }, .want = "u.x" },
        .{ .parts = &.{ "u", "x" }, .want = "u.x" },
        .{ .parts = &.{"x"}, .want = "x" },
        // A lone part is a name, never a prefix to drop.
        .{ .parts = &.{"$root"}, .want = "$root" },
        .{ .parts = &.{ "$root", "top" }, .want = "top" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.want, try flatReference(&file, a, &m, try hierIdent(&file, a, c.parts)));
    // With no module in hand the top's name is an ordinary first part.
    try std.testing.expectEqualStrings("top.u.x", try flatReference(&file, a, null, try hierIdent(&file, a, &.{ "top", "u", "x" })));
    // §6.2.1 "priority to the local scope": an instance named like the top keeps its part.
    const shadow: Ast.ModuleDecl = .{ .name = top, .ports = &.{}, .instances = &.{.{ .module = top, .name = top }} };
    try std.testing.expectEqualStrings("top.x", try flatReference(&file, a, &shadow, try hierIdent(&file, a, &.{ "top", "x" })));
}

test checkTypedPort {
    // §6.5.2.1: an untyped port "can be passed to instances of modules, but
    // cannot be accessed in a behavioral description" (#74). The top's net is
    // `ca`, so the joined node has a discipline; the child's port does not.
    const src =
        \\nature nv; units = "V"; access = V; abstol = 1u; endnature
        \\nature ni; units = "A"; access = I; abstol = 1p; endnature
        \\discipline ca; potential nv; flow ni; enddiscipline
        \\module top(p); inout p; ca p; mid u(p); endmodule
        \\module mid(c); inout c; {s} endmodule
        \\module leaf(c); inout c; ca c; analog I(c) <+ V(c); endmodule
    ;
    const cases = [_]struct { mid: []const u8, bad: bool }{
        // Probed and contributed with no local discipline: E0337, as at the top.
        .{ .mid = "analog I(c) <+ V(c);", .bad = true },
        // The second terminal of an access is the same port.
        .{ .mid = "ca q; analog I(q, c) <+ V(q);", .bad = true },
        // Legal neighbours: the child declares the discipline, or passes the
        // port only to an instance (structural, §3.6.2.4; §7.4 resolves it).
        .{ .mid = "ca c; analog I(c) <+ V(c);", .bad = false },
        .{ .mid = "leaf l(c);", .bad = false },
    };
    for (cases) |c| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{c.mid}));
        if (c.bad) {
            try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
            try std.testing.expect(fixture.hasCode(&f.bag, .E0337));
        } else {
            _ = try elaborate.elaborate(f.ctx());
            try std.testing.expect(!fixture.hasCode(&f.bag, .E0337));
        }
    }
}

test findModule {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parseWithPrelude(&f,
        \\module dup(p); inout p; electrical p; parameter real first = 1.0; endmodule
        \\module dup(p); inout p; electrical p; parameter real second = 1.0; endmodule
        \\paramset dps dup; parameter real x = 1.0; .second = x; endparamset
    );
    var fl = try fixture.flatten(&f);
    const user = f.file.userModules();
    // IEEE 1364-2005 §13.2.1.1: the last definition of a name is the module.
    try std.testing.expectEqual(&user[1], findModule(&fl, fixture.id(&f.file, "dup").?).?);
    // §6.4: a paramset name is selected by its instance, never by this lookup.
    try std.testing.expectEqual(@as(?*const Ast.ModuleDecl, null), findModule(&fl, fixture.id(&f.file, "dps").?));
    // Annex E: a Table E.1 row is found when no user module has the name,
    // and is a primitive; a user module never is.
    const resistor = findModule(&fl, fixture.id(&f.file, "resistor").?).?;
    try std.testing.expect(isPrimitive(&fl, resistor));
    try std.testing.expect(!isPrimitive(&fl, &user[1]));
    try std.testing.expectEqual(@as(?*const Ast.ModuleDecl, null), findModule(&fl, try f.file.intern(f.arena.allocator(), "nowhere")));
}

test "§6.4 a paramset chain that names nothing or closes on itself is E0904, and terminates" {
    for ([_][]const u8{
        "paramset a b; parameter real x = 1.0; endparamset paramset b a; parameter real y = 1.0; endparamset",
        "paramset a nowhere; parameter real x = 1.0; endparamset",
    }) |chain| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; a u(p); endmodule
            \\{s}
        , .{chain}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
        try std.testing.expect(fixture.hasCode(&f.bag, .E0904));
    }
}

test "IEEE 1364-2005 §13.2.1.1 of two same-named roots the last is the device, with W1152" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; parameter real first = 1.0; endmodule
        \\module top(p); inout p; electrical p; parameter real second = 1.0; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(&f.file.modules[1], d.top);
    try std.testing.expect(fixture.hasCode(&f.bag, .W1152));
}

/// Elaborates `text` on a `deep_stack` thread reserved for `depth` levels,
/// as `compileInArena` runs lowering (and so elaboration) for the parser's
/// `deepest`.
fn elaborateDeep(f: *fixture.Fixture, depth: usize) !elaborate.Design {
    return @import("base").deep_stack.run(depth, elaborate.elaborate, .{f.ctx()});
}

test "a chain of parameter defaults folds within the stack reserved for one default's depth" {
    // `q<i> = q<i-1> + 1+1+…` (`d` terms): an instance range reading the
    // last folds every default of the chain. Folded one inside the next,
    // the chain needs `links` times the stack reserved for the parse's
    // deepest expression (one default) and overflowed it (SIGSEGV).
    const d = 4000;
    const links = 32;
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "module kid(a); inout a; electrical a; endmodule\nmodule top(p); inout p; electrical p;\n");
    for (0..links) |i| {
        try text.print(gpa, "parameter integer q{d} = ", .{i});
        if (i != 0) try text.print(gpa, "q{d} + ", .{i - 1});
        for (0..d) |k| try text.appendSlice(gpa, if (k == 0) "1" else "+1");
        try text.appendSlice(gpa, ";\n");
    }
    try text.print(gpa, "kid u[q{d}:q{d}](p); endmodule\n", .{ links - 1, links - 1 });
    var f: fixture.Fixture = .{ .arena = .init(gpa) };
    defer f.deinit();
    try fixture.parse(&f, text.items);
    const design = try elaborateDeep(&f, d + 2);
    try std.testing.expectEqual(@as(usize, 2), design.units.len);
    try std.testing.expectEqualStrings(try f.arena.allocator().print("u[{d}].", .{links * d}), design.units[1].path);
}

test "parameter folds: a forward reference still folds, a cycle declines (E0909)" {
    // `a` reads `b`, declared after it; `c` and `e` read each other.
    for ([_]struct { []const u8, bool }{
        .{ "parameter integer a = b + 1; parameter integer b = 2; kid u[a:a](p);", true },
        .{ "parameter integer c = e; parameter integer e = c; kid u[c:c](p);", false },
    }) |case| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(
            \\module kid(a); inout a; electrical a; endmodule
            \\module top(p); inout p; electrical p; {s} endmodule
        , .{case[0]}));
        if (case[1]) {
            const d = try elaborate.elaborate(f.ctx());
            try std.testing.expectEqualStrings("u[3].", d.units[1].path);
        } else {
            try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
            try std.testing.expect(fixture.hasCode(&f.bag, .E0909));
        }
    }
}
