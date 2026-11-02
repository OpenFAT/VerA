//! IEEE 1364-2005 §3.7.1: an escaped identifier is `\` and any printable
//! characters up to white space, and "neither the leading backslash
//! character nor the terminating white space is considered to be part of
//! the identifier". So `\a[1] ` is one name, not `a` indexed by 1: the
//! class of the defparam `segment()` abort (`\a__g[1]__in1`). A row is a
//! feature (`Feature`: a bracket, a parenthesis, a dot, a `[k]` suffix, a
//! bare `[k]`) through one path; each of its seeds names every object of
//! two designs with fresh escaped identifiers holding that feature, and
//! runs them through the paths that resolve a name:
//! a three-level hierarchy with a two-segment `defparam` and hierarchical
//! references under `--run`, and named port connections and a named
//! parameter assignment under `--emit-rtlil`.
//!
//! The oracle is renaming: the same design with plain names (`n0`, `n1`,
//! ...) must behave the same. `--run` prints the hand-derived `8 2 7`
//! under both; `--emit-rtlil`'s text with each escaped name written as
//! its plain one is the plain design's text. (The VPI path,
//! `vpi_handle_by_name`, is `tests/vpi_escaped/`.)
//!
//! Contents:
//! - `pub const known`
//! - `pub fn rows(arena: Allocator, exe: []const u8, dir: []const u8) ![]const table.Row`
//! - `pub fn child(io: Io, feature: []const u8, pass: []const u8) ![]const u8`

const std = @import("std");
const vera = @import("vera");
const digital = @import("sim").digital;
const native = @import("digital");
const table = @import("table.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const known: []const table.Known = &.{};

/// Seeds per row: each row is one feature through one pass.
const seeds = 16;
const Pass = enum { run, emit_rtlil };

/// What every name of a row's designs holds, besides printable text
/// with none of `[].()\` (and no backtick: a directive inside a name is
/// not this test's question).
const Feature = enum {
    /// `[` or `]` inside, not ending the name.
    bracket,
    /// `(` or `)` anywhere.
    paren,
    /// `.` anywhere: a hierarchical name's separator, inside one name.
    dot,
    /// Ends in `[k]`, as `\a__g[1]__in1`'s gate-array names do.
    index_suffix,
    /// Is `[k]` and nothing else.
    index_only,
    /// Starts with `\`: `\\a ` is the name `\a`, not `a`.
    backslash,
};

/// The names a design takes, one per role.
const roles = 7;

pub fn rows(arena: Allocator, exe: []const u8, dir: []const u8) ![]const table.Row {
    var out: std.ArrayList(table.Row) = .empty;
    for (std.enums.values(Feature)) |f| for (std.enums.values(Pass)) |p| {
        try out.append(arena, .{
            .name = try arena.print("{t} --{s}", .{ f, if (p == .run) "run" else "emit-rtlil" }),
            .argv = try arena.dupe([]const u8, &.{ exe, dir, "escaped", @tagName(f), @tagName(p) }),
        });
    };
    return out.items;
}

/// One feature through one pass over every seed: "" when each escaped
/// design behaved as its plain twin, else the first seed's difference.
pub fn child(io: Io, feature: []const u8, pass: []const u8) ![]const u8 {
    const f = std.meta.stringToEnum(Feature, feature) orelse return error.UnknownFeature;
    const p = std.meta.stringToEnum(Pass, pass) orelse return error.UnknownPass;
    const arena = std.heap.page_allocator; // the child exits right after
    for (0..seeds) |seed| {
        const why = try one(arena, io, p, try names(arena, f, seed));
        if (why.len != 0) return arena.print("seed {d}: {s}", .{ seed, why });
    }
    return "";
}

// ---- private ----

/// Seed `seed`'s names for `f`: distinct, 3 to 12 printable characters.
fn names(arena: Allocator, f: Feature, seed: u64) ![roles][]const u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var out: [roles][]const u8 = undefined;
    var i: usize = 0;
    while (i < roles) {
        var text: std.ArrayList(u8) = .empty;
        for (0..r.intRangeAtMost(usize, 2, 8)) |_| try text.append(arena, while (true) {
            const x = r.intRangeAtMost(u8, 0x21, 0x7e);
            if (std.mem.findScalar(u8, "[].()\\`", x) == null) break x;
        });
        const at = r.uintAtMost(usize, text.items.len - 1);
        switch (f) {
            .bracket => try text.insert(arena, at, "[]"[r.uintLessThan(usize, 2)]),
            .paren => try text.insert(arena, r.uintAtMost(usize, text.items.len), "()"[r.uintLessThan(usize, 2)]),
            .dot => try text.insert(arena, r.uintAtMost(usize, text.items.len), '.'),
            .index_suffix => try text.print(arena, "[{d}]", .{r.uintLessThan(u8, 10)}),
            .backslash => try text.insert(arena, 0, '\\'),
            .index_only => {
                text.clearRetainingCapacity();
                try text.print(arena, "[{d}]", .{r.uintLessThan(u8, 100)});
            },
        }
        for (out[0..i]) |o| {
            if (std.mem.eql(u8, o, text.items)) break;
        } else {
            out[i] = text.items;
            i += 1;
        }
    }
    return out;
}

/// `\text ` for an escaped run, `n<role>` for the plain one.
fn ref(arena: Allocator, ns: ?[roles][]const u8, role: usize) ![]const u8 {
    return if (ns) |x| std.fmt.allocPrint(arena, "\\{s} ", .{x[role]}) else std.fmt.allocPrint(arena, "n{d}", .{role});
}

/// The `--run` design: `M` (0) with parameter `P` (1) and reg `R` (2),
/// in `Q` (3) as `K` (4), in `top` as `I` (5) and `J` (6). The defparam
/// moves `I.K.P` to 7, so `I.K.R` is 8, `J.K.R` 2.
fn runDesign(arena: Allocator, ns: ?[roles][]const u8) ![]const u8 {
    var n: [roles][]const u8 = undefined;
    for (&n, 0..) |*x, i| x.* = try ref(arena, ns, i);
    return std.fmt.allocPrint(arena,
        \\module {0s};
        \\  parameter {1s} = 1;
        \\  reg [7:0] {2s};
        \\  initial {2s} = {1s} + 1;
        \\endmodule
        \\module {3s};
        \\  {0s} {4s} ();
        \\endmodule
        \\module top;
        \\  {3s} {5s} ();
        \\  {3s} {6s} ();
        \\  defparam {5s}.{4s}.{1s} = 7;
        \\  initial #1 $display("%0d %0d %0d", {5s}.{4s}.{2s}, {6s}.{4s}.{2s}, {5s}.{4s}.{1s});
        \\endmodule
        \\
    , .{ n[0], n[1], n[2], n[3], n[4], n[5], n[6] });
}

/// The `--emit-rtlil` design: `M` (0) with ports `A` (1), `R` (2) and
/// parameter `P` (3), in `top` as `I` (4, `P` set to 7 by name) and `J`
/// (5), connected by name. (`--emit-rtlil` refuses a defparam.)
fn rtlilDesign(arena: Allocator, ns: ?[roles][]const u8) ![]const u8 {
    var n: [roles][]const u8 = undefined;
    for (&n, 0..) |*x, i| x.* = try ref(arena, ns, i);
    return std.fmt.allocPrint(arena,
        \\module {0s}({1s}, {2s});
        \\  input [7:0] {1s};
        \\  output [7:0] {2s};
        \\  parameter {3s} = 1;
        \\  assign {2s} = {1s} + {3s};
        \\endmodule
        \\module top(a, y, z);
        \\  input [7:0] a;
        \\  output [7:0] y, z;
        \\  {0s} #(.{3s}(7)) {4s} (.{1s}(a), .{2s}(y));
        \\  {0s} {5s} (.{1s}(a), .{2s}(z));
        \\endmodule
        \\
    , .{ n[0], n[1], n[2], n[3], n[4], n[5] });
}

fn one(arena: Allocator, io: Io, p: Pass, ns: [roles][]const u8) ![]const u8 {
    const opts: digital.Options = .{ .file_name = "t.v", .io = io };
    switch (p) {
        .run => {
            const want = "8 2 7\n";
            for ([_]?[roles][]const u8{ null, ns }) |which| {
                const source = try runDesign(arena, which);
                var bag: vera.diag.Bag = .init(arena);
                var out: Io.Writer.Allocating = .init(arena);
                digital.run(arena, source, opts, &bag, &out.writer) catch |e| return arena.print("{t}: {s} on\n{s}", .{ e, try messages(arena, &bag), source });
                if (bag.failed() or !std.mem.eql(u8, out.written(), want))
                    return arena.print("printed `{s}`, want `{s}`, on\n{s}", .{ out.written(), want, source });
            }
            return "";
        },
        .emit_rtlil => {
            var texts: [2][]const u8 = undefined;
            for ([_]?[roles][]const u8{ null, ns }, &texts) |which, *text| {
                const source = try rtlilDesign(arena, which);
                var bag: vera.diag.Bag = .init(arena);
                text.* = native.rtlil.emit(arena, source, opts, &bag) catch |e| return arena.print("{t} {s} on\n{s}", .{ e, try messages(arena, &bag), source });
            }
            // Longest first, so a name inside another is not cut out of it.
            var renamed = texts[1];
            var order: [roles]usize = undefined;
            for (&order, 0..) |*o, i| o.* = i;
            std.mem.sort(usize, order[0..6], ns, struct {
                fn longer(x: [roles][]const u8, a: usize, b: usize) bool {
                    return x[a].len > x[b].len;
                }
            }.longer);
            for (order[0..6]) |i| renamed = try std.mem.replaceOwned(u8, arena, renamed, ns[i], try std.fmt.allocPrint(arena, "n{d}", .{i}));
            if (!std.mem.eql(u8, renamed, texts[0]))
                return arena.print("the escaped design's RTLIL, renamed, is not the plain one's:\n--- plain\n{s}\n--- escaped, renamed\n{s}\n--- escaped\n{s}", .{ texts[0], renamed, texts[1] });
            return "";
        },
    }
}

/// The bag's messages, one a line.
fn messages(arena: Allocator, bag: *const vera.diag.Bag) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..bag.count()) |i| try out.print(arena, "{t} {s}\n", .{ bag.at(i).code, bag.at(i).message });
    return out.items;
}

test "seeded names: distinct, printable, each with its feature" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    for (std.enums.values(Feature)) |f| for (0..seeds) |seed| {
        const ns = try names(arena_state.allocator(), f, seed);
        for (ns, 0..) |a, i| {
            for (a) |c| try std.testing.expect(c > ' ' and c < 0x7f and c != '`');
            for (ns[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
            const ends_index = a[a.len - 1] == ']' and std.mem.findScalar(u8, a, '[') != null;
            try std.testing.expect(switch (f) {
                .bracket => std.mem.findAny(u8, a, "[]") != null and !ends_index,
                .paren => std.mem.findAny(u8, a, "()") != null,
                .dot => std.mem.findScalar(u8, a, '.') != null,
                .index_suffix => ends_index and a.len > 3,
                .index_only => ends_index and a[0] == '[',
                .backslash => a[0] == '\\' and std.mem.findScalar(u8, a[1..], '\\') == null,
            });
        }
    };
}
