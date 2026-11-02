//! Flat names: an instance path and a local name → the injective flat name
//! the lowered design uses (§6.7, `design.sep`), the unit's rename map, and
//! the path keys `defparam`/`ooc` look up without allocating. Also §6.6.2's
//! unnamed generate scopes no hierarchical name may open.
//! Cites: LRM §6.2.1, §6.6.1, §6.6.2, §6.6.3, §6.7, §6.7.1; IEEE 1364-2005
//! §12.6.
//!
//! Contents:
//! - `pub const PathKey = struct`
//! -   `pub const Context = struct`
//! -     `pub fn hash(_: Context, k: PathKey) u64`
//! -     `pub fn eql(_: Context, k: PathKey, stored: []const u8) bool`
//! - `pub fn flatReference(file: *const Ast.SourceFile, arena: std.mem.Allocator, module: ?*const Ast.ModuleDecl, e: Ast.ExprId) std.mem.Allocator.Error![]const u8`
//! - `pub fn unnamedGenScopes(file: *const Ast.SourceFile, arena: std.mem.Allocator, m: *const Ast.ModuleDecl, path: []const u8, out: *std.ArrayList([]const u8)) std.mem.Allocator.Error!void`
//! - `pub fn namesUnnamedGen(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, name: Ast.StrId) bool`
//! - `pub fn join(self: *Flatten, path: []const u8, local: Ast.StrId) design.Error!Ast.StrId`
//! - `pub fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) design.Error!void`
//! - `pub fn flat(self: *Flatten, local: Ast.StrId) Ast.StrId`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const sep = design.sep;
const Unit = Flatten.Unit;

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
    // Not done in elaboration's clone: the top module's body is never cloned,
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
        if (i != 0) try out.append(arena, sep);
        try out.appendSlice(arena, file.str(p));
    }
    assert(parts.len != 0); // a prefix is dropped only ahead of another part
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
    if (path.len != 0) assert(path[path.len - 1] == sep);
    for (m.analog) |blk| try genScopesIn(file, arena, blk.body, path, out);
}

/// Whether `name` is the §6.6.3 external name of an unnamed generate block
/// at `m`'s own scope (not nested in a named block): the first part of a
/// hierarchical name written in `m` that would open it (§6.6.2, E0998).
pub fn namesUnnamedGen(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    assert(name != .none);
    for (m.analog) |blk| if (unnamedGenIn(file, blk.body, name)) return true;
    return false;
}

/// Returns `path ++ local`, interned. The flat name is the §6.7 path, so the
/// path table (`Design.names`) needs no row for it.
pub fn join(self: *Flatten, path: []const u8, local: Ast.StrId) design.Error!Ast.StrId {
    assert(local != .none);
    if (path.len != 0) assert(path[path.len - 1] == sep);
    const s = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(local) });
    return self.ctx.file.intern(self.ctx.arena, s);
}

/// Binds `local` to its flat name `path ++ local` in `unit`'s rename map,
/// unless it is already bound (a port joined to the parent's net).
pub fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) design.Error!void {
    assert(local != .none);
    if (path.len != 0) assert(path[path.len - 1] == sep);
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

// ---- private ----

fn genScopesIn(file: *const Ast.SourceFile, arena: std.mem.Allocator, id: Ast.StmtId, prefix: []const u8, out: *std.ArrayList([]const u8)) std.mem.Allocator.Error!void {
    if (prefix.len != 0) assert(prefix[prefix.len - 1] == sep);
    if (id == .none) return;
    switch (file.stmt(id)) {
        .block => |b| {
            var inner = prefix;
            if (b.gen_name != .none) {
                inner = try arena.print("{s}{s}{c}", .{ prefix, file.str(b.gen_name), sep });
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

fn unnamedGenIn(file: *const Ast.SourceFile, id: Ast.StmtId, name: Ast.StrId) bool {
    assert(name != .none);
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

/// A `.hier_ident` row over `parts`, interned into `file`.
fn hierIdent(file: *Ast.SourceFile, a: std.mem.Allocator, parts: []const []const u8) !Ast.ExprId {
    const ids = try a.alloc(Ast.StrId, parts.len);
    for (parts, ids) |p, *i| i.* = try file.intern(a, p);
    return file.exprs.add(a, .{ .tag = .hier_ident, .extra = try file.exprs.addStrList(a, ids) });
}

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
