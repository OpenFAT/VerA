//! The two structural `wreal` rules (LRM §3.7, §6.5.3; §7.4.2 applies §3.7 to
//! real-value nets): parsed source file in, E0918 (a wreal net with a second
//! driver in its module) and E0919 (a port joining a wreal to a net type other
//! than wire/tri/wreal) out. Shared by the compiler and the digital runner.
//!
//! Contents:
//! - `pub fn check(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag) std.mem.Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const diag = @import("diag");
const Ast = @import("ast.zig");
const testing = std.testing;

/// Token index k starts at byte 10·k, so a diagnostic's span names its token.
const test_starts = [_]u32{ 0, 10, 20, 30, 40, 50, 60, 70, 80, 90 };

// ponytail: drivers are counted per module (assigns and the declaration's
// own `=`); a driver arriving through a port is not. Counting those needs the
// elaborated net, which `declare` builds after this.

/// Reports every E0918 and E0919 in `file` into `bag`. Runs on the parsed file,
/// before elaboration, so a violation gets the LRM's reason. `starts` is the
/// token list's `.start` column and places each diagnostic; a token index
/// past it is clamped to the last token, so `starts` must not be empty (a
/// token list always ends with `.eof`). Asserts that it is not, wherever a
/// diagnostic is placed.
/// An ordered connection binds the n-th port of A.1.3's `list_of_ports`, so a
/// concatenated port (`.p({a, b})`) counts once.
/// Fails only with `OutOfMemory`, from `bag`.
pub fn check(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag) std.mem.Allocator.Error!void {
    const ex = &file.exprs;
    // Both rules need a wreal, which most files never declare; the walk
    // below is O(connections × declarations).
    for (file.modules) |*m| {
        if (hasWreal(m)) break;
    } else return;
    for (file.modules) |*m| {
        for (m.nets) |n| if (n.kind == .wreal) try wrealDrivers(file, starts, bag, m, n.name, n.init != .none);
        for (m.ports) |p| if (p.kind == .wreal) try wrealDrivers(file, starts, bag, m, p.name, false);
        const parent_wreal = hasWreal(m);
        for (m.instances) |inst| {
            // The last same-named module (IEEE 1364-2005 §13.2.1.1), as
            // `elaborate.findModule` binds it.
            var k = file.modules.len;
            const child = while (k > 0) {
                k -= 1;
                if (file.modules[k].name == inst.module) break &file.modules[k];
            } else continue;
            // E0919 needs a wreal on one side of the port.
            if (!parent_wreal and !hasWreal(child)) continue;
            for (inst.ports, 0..) |conn, i| {
                if (conn.expr == .none or ex.tag(conn.expr) != .ident) continue;
                const port = if (conn.name == .none) (nthPort(child.ports, i) orelse continue) else for (child.ports) |p| {
                    if (p.connName() == conn.name) break p;
                } else continue;
                // A name the parent never declared as a net is a variable
                // (a real expression, which 3.7 allows) or an implicit wire.
                const outer = netKind(m, ex.strOf(conn.expr)) orelse continue;
                if ((outer == .wreal) == (port.kind == .wreal)) continue;
                const other = if (outer == .wreal) port.kind else outer;
                assert(other != .wreal); // exactly one side is a wreal
                if (other == .wire or other == .tri) continue;
                assert(starts.len != 0);
                const start = starts[@min(conn.main_tok, starts.len - 1)];
                try bag.add(.lower, .E0919, .{ .start = start, .end = start }, "`{s}` is a {s} and port `{s}` is a {s}", .{
                    file.str(ex.strOf(conn.expr)), @tagName(outer), file.str(port.name), @tagName(port.kind),
                });
            }
        }
    }
}

// ---- private ----

fn wrealDrivers(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag, m: *const Ast.ModuleDecl, name: Ast.StrId, declared: bool) std.mem.Allocator.Error!void {
    var count: u32 = @intFromBool(declared);
    for (m.assigns) |a| {
        if (a.target == .none or file.exprs.tag(a.target) != .ident or file.exprs.strOf(a.target) != name) continue;
        count += 1;
        if (count != 2) continue;
        assert(starts.len != 0);
        const start = starts[@min(a.main_tok, starts.len - 1)];
        try bag.add(.lower, .E0918, .{ .start = start, .end = start }, "`{s}` is already driven", .{file.str(name)});
    }
}

// The `n`-th A.1.3 port of `ports`, or null past the last. The parts of a
// concatenated port after its first (`concat_rest`) are the same port.
fn nthPort(ports: []const Ast.Port, n: usize) ?Ast.Port {
    if (n >= ports.len) return null;
    var k: usize = 0;
    for (ports) |p| {
        if (p.concat_rest) continue;
        if (k == n) return p;
        k += 1;
    }
    assert(k <= n);
    return null;
}

/// Whether `m` declares a wreal net or port.
fn hasWreal(m: *const Ast.ModuleDecl) bool {
    assert(m.name != .none);
    for (m.ports) |p| if (p.kind == .wreal) return true;
    for (m.nets) |n| if (n.kind == .wreal) return true;
    return false;
}

// ponytail: a module that does declare a wreal still pays O(connections ×
// declarations) here; index its nets by name if a wreal netlist gets large.

/// The declared net type of `name` in `m`, or null if `m` declares no such net.
fn netKind(m: *const Ast.ModuleDecl, name: Ast.StrId) ?Ast.NetKind {
    assert(name != .none);
    for (m.ports) |p| if (p.name == name) return p.kind;
    for (m.nets) |n| if (n.name == name) return n.kind;
    return null;
}

fn ident(f: *Ast.SourceFile, a: std.mem.Allocator, name: []const u8) !Ast.ExprId {
    return f.exprs.add(a, .{ .tag = .ident, .str = try f.intern(a, name) });
}

/// Expects exactly `want` diagnostics, as (code, span start) pairs in order.
fn expectReports(bag: *const diag.Bag, want: []const struct { diag.Code, u32 }) !void {
    try testing.expectEqual(want.len, bag.count());
    for (want, 0..) |w, i| {
        const r = bag.at(i);
        try testing.expectEqual(w[0], r.code);
        try testing.expectEqual(w[1], r.span.start);
    }
}

test "E0918: a wreal's second driver in its module, the declaration's own `=` included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Ast.SourceFile = .empty;
    const w = try ident(&f, a, "w");
    const d = try ident(&f, a, "d");
    const p = try ident(&f, a, "p");
    const v = try ident(&f, a, "v");
    const one = try f.exprs.addInt(a, 0, 1);
    // module m(p); wreal p; wreal w; wreal d = 1; wire v;
    //   assign w = 1; assign w = 1; assign w = 1;  // E0918 at the second only
    //   assign d = 1;                              // E0918: the `=` drove it first
    //   assign p = 1; assign p = 1;                // E0918: a port is a net too
    //   assign v = 1; assign v = 1;                // a wire may have many (§3.7 is wreal's)
    const ports = [_]Ast.Port{.{ .name = f.exprs.strOf(p), .kind = .wreal }};
    const nets = [_]Ast.NetDecl{
        .{ .name = f.exprs.strOf(w), .kind = .wreal },
        .{ .name = f.exprs.strOf(d), .kind = .wreal, .init = one },
        .{ .name = f.exprs.strOf(v) },
    };
    const assigns = [_]Ast.ContAssign{
        .{ .target = w, .value = one, .main_tok = 1 },
        .{ .target = w, .value = one, .main_tok = 2 },
        .{ .target = w, .value = one, .main_tok = 3 },
        .{ .target = d, .value = one, .main_tok = 4 },
        .{ .target = p, .value = one, .main_tok = 5 },
        .{ .target = p, .value = one, .main_tok = 6 },
        .{ .target = v, .value = one, .main_tok = 7 },
        .{ .target = v, .value = one, .main_tok = 8 },
    };
    const mods = [_]Ast.ModuleDecl{.{ .name = try f.intern(a, "m"), .ports = &ports, .nets = &nets, .assigns = &assigns }};
    f.modules = &mods;
    var bag: diag.Bag = .init(a);
    try check(&f, &test_starts, &bag);
    // Nets first, in declaration order, then ports.
    try expectReports(&bag, &.{ .{ .E0918, 20 }, .{ .E0918, 40 }, .{ .E0918, 60 } });
}

test "E0919: a port joining a wreal to a net type other than wire, tri or wreal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Ast.SourceFile = .empty;
    const rw = try ident(&f, a, "rw");
    const wa = try ident(&f, a, "wa");
    const tr = try ident(&f, a, "tr");
    const undeclared = try ident(&f, a, "u");
    const p0 = try f.intern(a, "p0");
    const p1 = try f.intern(a, "p1");
    // module child(p0, p1, p2); wreal p0; wand p1; (p2 a wire)
    const ports = [_]Ast.Port{
        .{ .name = p0, .kind = .wreal },
        .{ .name = p1, .kind = .wand },
        .{ .name = try f.intern(a, "p2") },
    };
    const nets = [_]Ast.NetDecl{
        .{ .name = f.exprs.strOf(rw), .kind = .wreal },
        .{ .name = f.exprs.strOf(wa), .kind = .wand },
        .{ .name = f.exprs.strOf(tr), .kind = .tri },
    };
    // child u0(rw, rw, rw): wreal-wreal, wreal-wand (E0919), wreal-wire.
    const ordered = [_]Ast.PortConn{
        .{ .expr = rw, .main_tok = 1 },
        .{ .expr = rw, .main_tok = 2 },
        .{ .expr = rw, .main_tok = 3 },
    };
    const named = [_]Ast.PortConn{
        .{ .name = p0, .expr = wa, .main_tok = 4 }, // wand-wreal: E0919
        .{ .name = p0, .expr = tr, .main_tok = 5 }, // tri-wreal: §3.7 allows it
        .{ .name = p0, .expr = undeclared, .main_tok = 6 }, // no net: a variable or implicit wire
        .{ .name = p0, .main_tok = 7 }, // unconnected
        .{ .name = p1, .expr = tr, .main_tok = 8 }, // no wreal on either side
    };
    const child = try f.intern(a, "child");
    const insts = [_]Ast.Instance{
        .{ .module = child, .name = try f.intern(a, "u0"), .ports = &ordered },
        .{ .module = child, .name = try f.intern(a, "u1"), .ports = &named },
    };
    const mods = [_]Ast.ModuleDecl{
        .{ .name = child, .ports = &ports },
        .{ .name = try f.intern(a, "top"), .ports = &.{}, .nets = &nets, .instances = &insts },
    };
    f.modules = &mods;
    var bag: diag.Bag = .init(a);
    try check(&f, &test_starts, &bag);
    try expectReports(&bag, &.{ .{ .E0919, 20 }, .{ .E0919, 40 } });
}

test "E0919 through an ordered connection after a concatenated port binds the n-th port" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Ast.SourceFile = .empty;
    const q = try ident(&f, a, "q");
    const wa = try ident(&f, a, "wa");
    // module child(.bus({x, y}), z); wreal z;  — A.1.3: two ports, three parts.
    const bus = try f.intern(a, "bus");
    const ports = [_]Ast.Port{
        .{ .name = try f.intern(a, "x"), .external_name = bus },
        .{ .name = try f.intern(a, "y"), .external_name = bus, .concat_rest = true },
        .{ .name = try f.intern(a, "z"), .kind = .wreal },
    };
    const nets = [_]Ast.NetDecl{ .{ .name = f.exprs.strOf(q) }, .{ .name = f.exprs.strOf(wa), .kind = .wand } };
    // child u(q, wa): the second connection is port `z`, a wreal, so E0919.
    const conns = [_]Ast.PortConn{ .{ .expr = q, .main_tok = 1 }, .{ .expr = wa, .main_tok = 2 } };
    const child = try f.intern(a, "child");
    const insts = [_]Ast.Instance{.{ .module = child, .name = try f.intern(a, "u"), .ports = &conns }};
    const mods = [_]Ast.ModuleDecl{
        .{ .name = child, .ports = &ports },
        .{ .name = try f.intern(a, "top"), .ports = &.{}, .nets = &nets, .instances = &insts },
    };
    f.modules = &mods;
    var bag: diag.Bag = .init(a);
    try check(&f, &test_starts, &bag);
    try expectReports(&bag, &.{.{ .E0919, 20 }});
}

test "E0919 binds the last module of a name (IEEE 1364-2005 §13.2.1.1)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Ast.SourceFile = .empty;
    const wa = try ident(&f, a, "wa");
    const p = try f.intern(a, "p");
    const child = try f.intern(a, "child");
    const wire_port = [_]Ast.Port{.{ .name = p }};
    const wreal_port = [_]Ast.Port{.{ .name = p, .kind = .wreal }};
    const nets = [_]Ast.NetDecl{.{ .name = f.exprs.strOf(wa), .kind = .wand }};
    const conns = [_]Ast.PortConn{.{ .expr = wa, .main_tok = 3 }};
    const insts = [_]Ast.Instance{.{ .module = child, .name = try f.intern(a, "u"), .ports = &conns }};
    const mods = [_]Ast.ModuleDecl{
        .{ .name = child, .ports = &wire_port },
        .{ .name = try f.intern(a, "top"), .ports = &.{}, .nets = &nets, .instances = &insts },
        .{ .name = child, .ports = &wreal_port },
    };
    f.modules = &mods;
    var bag: diag.Bag = .init(a);
    try check(&f, &test_starts, &bag);
    try expectReports(&bag, &.{.{ .E0919, 30 }});
}

test "E0919 from the parent's side, into a child that declares no wreal; no wreal anywhere reports nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Ast.SourceFile = .empty;
    const rw = try ident(&f, a, "rw");
    const p = try f.intern(a, "p");
    const child = try f.intern(a, "child");
    // module child(p); wand p;  module top; wreal rw; child u(rw);
    const wand_port = [_]Ast.Port{.{ .name = p, .kind = .wand }};
    const nets = [_]Ast.NetDecl{.{ .name = f.exprs.strOf(rw), .kind = .wreal }};
    const conns = [_]Ast.PortConn{.{ .expr = rw, .main_tok = 4 }};
    const insts = [_]Ast.Instance{.{ .module = child, .name = try f.intern(a, "u"), .ports = &conns }};
    const mods = [_]Ast.ModuleDecl{
        .{ .name = child, .ports = &wand_port },
        .{ .name = try f.intern(a, "top"), .ports = &.{}, .nets = &nets, .instances = &insts },
    };
    f.modules = &mods;
    var bag: diag.Bag = .init(a);
    try check(&f, &test_starts, &bag);
    try expectReports(&bag, &.{.{ .E0919, 40 }});
    // The same netlist with `rw` a `wor`: no wreal on either side.
    const wor = [_]Ast.NetDecl{.{ .name = f.exprs.strOf(rw), .kind = .wor }};
    const plain = [_]Ast.ModuleDecl{ mods[0], .{ .name = mods[1].name, .ports = &.{}, .nets = &wor, .instances = &insts } };
    f.modules = &plain;
    var quiet: diag.Bag = .init(a);
    try check(&f, &test_starts, &quiet);
    try expectReports(&quiet, &.{});
}
