//! IEEE 1364-2005 §18.1/§18.2 four-state value change dump: the `$dump*`
//! calls and every change of a dumped slot (the engine's value-change hook)
//! in; the VCD file out, header at the end of the `$dumpvars` step (§18.1.3),
//! then one `#time` section per step of the variables that changed (§18.1.4).
//! `Vcd` is shared by the interpreter and a native executable: the design
//! through `Catalog`, the values through the engine's `src` (`Vcd.tick`).
//! Also cited: §17.4.1 (`$finish` before the step's dump), §18.4.1 (the
//! header's `$date` and `$version`).
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
const compile = @import("compile.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const bitChar = @import("net.zig").bitChar;

/// The §18.1 tasks: `$dumpfile`, `$dumpvars`, `$dumpoff`, `$dumpon`,
/// `$dumpall`, `$dumplimit`, `$dumpflush`.
pub const Op = enum { file, vars, off, on, all, limit, flush };

/// What `$dumpvars` can select, fixed at elaboration: every scope, and each
/// instance scope's variables in declaration order (ports, nets, variables,
/// then named events; no arrays or parameters).
pub const Catalog = struct {
    scopes: []const Scope,
    /// Scope s's variables: `vars[var_start[s]..var_start[s + 1]]`.
    var_start: []const u32,
    vars: []const Var,
    /// `Run.finest`: ticks are this power of ten of a second.
    finest: i32,
};

/// One scope of a `Catalog`.
pub const Scope = struct {
    /// `$scope module name $end`, or `begin` for a generate iteration.
    line: []const u8,
    parent: u32,
    lexical: bool,
    /// Walked as a child of `parent`: a plain named block is not.
    child: bool,
};

/// One `$var`: `head` up to its identifier code, `tail` after it. `off` is
/// the slot's first plane word in a native executable.
pub const Var = struct { slot: u32, off: u32 = 0, width: u32, real: bool, event: bool = false, head: []const u8, tail: []const u8 };

/// `$dumpvars` names a scope (with its level count) or a variable.
pub const Target = union(enum) { scope: u32, slot: u32 };

/// One identifier code (§18.2.1): a catalog variable and the value last
/// written for it, both planes. Two references to one slot (a port
/// collapsed onto its parent's net) share the code, which §18.2.3.7 b)
/// permits.
const Code = struct {
    v: u32,
    last: []u64,
    /// An event's code: triggered in this time step (§18.2.2).
    fired: bool = false,

    // Budget: `changes` walks every code each dumped step.
    comptime {
        std.debug.assert(@sizeOf(Code) <= 24);
        std.debug.assert(@sizeOf(Var) <= 48);
    }
};

/// Why a dump stops; `message` gives each non-memory, non-writer one's text.
pub const Failure = error{ NoFilesystem, CannotCreate, CannotWrite, DumpvarsTime } || std.mem.Allocator.Error || std.Io.Writer.Error;

/// The text of a `Failure` other than memory and writing, with the file's name.
pub fn message(e: Failure) []const u8 {
    return switch (e) {
        error.NoFilesystem => "$dumpvars needs a filesystem to write `{s}`",
        error.CannotCreate => "cannot create the dump file `{s}`",
        error.CannotWrite => "cannot write the dump file `{s}`",
        error.DumpvarsTime => "§18.1.2: every $dumpvars shall execute at the same simulation time",
        error.OutOfMemory, error.WriteFailed => "the dump file `{s}` failed",
    };
}

/// The dump's state and writer.
pub const Vcd = struct {
    name: []const u8 = "dump.vcd",
    /// The `$dumpfile` call as written (`callText`), for §18.2.3.8's
    /// `$version`; null when none ran.
    call: ?[]const u8 = null,
    /// §18.1.2 the `$dumpvars` selection: scopes with their level count
    /// (0 = every level below) and single variables, by slot.
    scopes: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    slots: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The time the `$dumpvars` calls ran at, and the one to blame.
    selected_at: ?u64 = null,
    tok: u32 = 0,
    started: bool = false,
    on: bool = true,
    /// One end-of-step tick however many dumped values moved; the engine
    /// sets it when it queues one.
    pending: bool = false,
    codes: std.ArrayList(Code) = .empty,
    file: ?std.Io.File = null,
    pos: u64 = 0,
    limit: ?u64 = null,
    /// §18.1.5: the limit was reached and dumping has stopped for good.
    limited: bool = false,
    last_time: ?u64 = null,

    /// §18.1.1 `$dumpfile`: the name, unless dumping has begun or it is
    /// null (an x or z bit); `call` is the call as written.
    pub fn setFile(self: *Vcd, gpa: std.mem.Allocator, name: ?[]const u8, call: []const u8) Failure!void {
        if (self.started) return;
        self.name = try gpa.dupe(u8, name orelse return);
        self.call = try gpa.dupe(u8, call);
    }

    /// §18.1.2 one `$dumpvars` at time `now`: `levels` applies to the scopes
    /// in `targets` ("and not to individual variables"). Dumping starts at
    /// the end of the time unit (§18.1.3), so the engine queues a tick.
    pub fn select(self: *Vcd, gpa: std.mem.Allocator, now: u64, tok: u32, levels: u32, targets: []const Target) Failure!void {
        if (self.selected_at) |t| if (t != now or self.started) return error.DumpvarsTime;
        self.selected_at = now;
        self.tok = tok;
        for (targets) |t| switch (t) {
            .scope => |sc| try self.scopes.put(gpa, sc, levels),
            .slot => |sl| try self.slots.put(gpa, sl, {}),
        };
    }

    /// §18.2.2 named event `slot` was triggered: its code is written as a
    /// marker at the end of the step. The engine asks for the tick.
    pub fn fire(self: *Vcd, cat: *const Catalog, slot: u32) void {
        // ponytail: a scan of the codes per trigger; a slot index when a
        // design dumps many events.
        for (self.codes.items) |*c| if (cat.vars[c.v].slot == slot) {
            c.fired = true;
        };
    }

    /// `$dumpoff`, `$dumpon` and `$dumpall` (§18.1.3, §18.1.4); every other
    /// task has nothing to write. `src` as in `tick`.
    pub fn control(self: *Vcd, a: std.mem.Allocator, io: ?std.Io, cat: *const Catalog, src: anytype, now: u64, op: Op) Failure!void {
        switch (op) {
            .off => if (self.started and self.on) {
                try self.changes(a, io, cat, src, now);
                try self.checkpoint(a, io, cat, src, now, "$dumpoff", true);
                self.on = false;
            },
            .on => if (self.started and !self.on) {
                self.on = true;
                try self.checkpoint(a, io, cat, src, now, "$dumpon", false);
            },
            .all => if (self.started and self.on) {
                try self.changes(a, io, cat, src, now);
                try self.checkpoint(a, io, cat, src, now, "$dumpall", false);
            },
            // Every section is written as it happens, so there is no buffer
            // of this writer's own for §18.1.6 to empty.
            .file, .vars, .limit, .flush => {},
        }
    }

    /// The end of a time step with dumped changes, or the first one after
    /// `$dumpvars`: the header and the initial `$dumpvars` section, or the
    /// changes. `src` is the engine: `src.dumpPlanes(v, out)` copies catalog
    /// variable `v`'s value planes into `out`, and `src.dumpSlot(slot)` makes
    /// a change of `slot` queue a tick. Codes are allocated from `gpa`.
    pub fn tick(self: *Vcd, gpa: std.mem.Allocator, a: std.mem.Allocator, io: ?std.Io, cat: *const Catalog, src: anytype, now: u64) Failure!void {
        self.pending = false;
        if (self.started) return self.changes(a, io, cat, src, now);
        try self.header(gpa, a, io orelse return error.NoFilesystem, cat, src);
        try self.checkpoint(a, io, cat, src, now, "$dumpvars", false);
    }

    fn put(self: *Vcd, io: ?std.Io, bytes: []const u8) Failure!void {
        if (self.limited or bytes.len == 0) return;
        const f = self.file orelse return;
        var out = bytes;
        // §18.1.5: at the limit "the dumping stops, and a comment is inserted".
        if (self.limit) |lim| if (self.pos + bytes.len > lim) {
            out = "$comment $dumplimit reached $end\n";
            self.limited = true;
        };
        f.writePositionalAll(io.?, out, self.pos) catch return error.CannotWrite; // `header` opened it with `io`
        self.pos += out.len;
    }

    fn header(self: *Vcd, gpa: std.mem.Allocator, a: std.mem.Allocator, io: std.Io, cat: *const Catalog, src: anytype) Failure!void {
        self.file = std.Io.Dir.cwd().createFile(io, self.name, .{}) catch return error.CannotCreate;
        self.started = true;
        var w: std.Io.Writer.Allocating = .init(a);
        // §18.2.3.8: "If a variable or an expression was used to specify the
        // filename within $dumpfile, the unevaluated variable or expression
        // literal shall appear in the $version string."
        try preamble(&w.writer, io, self.call orelse try a.print("$dumpfile(\"{s}\")", .{self.name}), cat.finest);
        // Every top-level module is a root: scope 0 and each scope that is
        // its own parent.
        for (cat.scopes, 0..) |sc, i| if (i == 0 or sc.parent == i) try self.dumpScope(gpa, &w, cat, src, @intCast(i), null);
        try w.writer.writeAll("$enddefinitions $end\n");
        try self.put(io, w.written());
    }

    /// One scope and what it dumps, or nothing when nothing below it is
    /// selected. `inherited` is the level count a selected ancestor passes
    /// down: null none, 0 every level, n that many more.
    fn dumpScope(self: *Vcd, gpa: std.mem.Allocator, aw: *std.Io.Writer.Allocating, cat: *const Catalog, src: anytype, s: u32, inherited: ?u32) Failure!void {
        const w = &aw.writer;
        const info = cat.scopes[s];
        const own = self.scopes.get(s);
        const eff: ?u32 = if (inherited == null) own else if (own == null) inherited else if (inherited.? == 0 or own.? == 0) 0 else @max(inherited.?, own.?);
        const mark = aw.written().len;
        try w.writeAll(info.line);
        const body = aw.written().len;
        for (cat.vars[cat.var_start[s]..cat.var_start[s + 1]], cat.var_start[s]..) |v, i| {
            if (eff == null and !self.slots.contains(v.slot)) continue;
            const code: u32 = for (self.codes.items, 0..) |c, j| {
                if (cat.vars[c.v].slot == v.slot) break @intCast(j);
            } else blk: {
                try self.codes.append(gpa, .{ .v = @intCast(i), .last = try gpa.alloc(u64, 2 * words(v.width)) });
                src.dumpSlot(v.slot);
                break :blk @intCast(self.codes.items.len - 1);
            };
            try w.writeAll(v.head);
            try codeText(w, code);
            try w.writeAll(v.tail);
        }
        // A generate iteration is a `begin` scope of its instance, not a level.
        const down: ?u32 = if (info.lexical) eff else if (eff) |n| (if (n == 0) 0 else if (n == 1) null else n - 1) else null;
        for (cat.scopes, 0..) |child, i| {
            if (i == 0 or i == s or child.parent != s or !child.child) continue;
            try self.dumpScope(gpa, aw, cat, src, @intCast(i), down);
        }
        if (aw.written().len == body) {
            aw.shrinkRetainingCapacity(mark);
            return;
        }
        try w.writeAll("$upscope $end\n");
    }

    /// `#time`, once per time step however many sections it carries.
    fn time(self: *Vcd, w: *std.Io.Writer, now: u64) Failure!void {
        if (self.last_time == now) return;
        self.last_time = now;
        try w.print("#{d}\n", .{now});
    }

    /// §18.2.3.9-§18.2.3.12: a section holding every dumped variable (as x
    /// for `$dumpoff`), which then counts as dumped.
    fn checkpoint(self: *Vcd, a: std.mem.Allocator, io: ?std.Io, cat: *const Catalog, src: anytype, now: u64, keyword: []const u8, as_x: bool) Failure!void {
        var w: std.Io.Writer.Allocating = .init(a);
        try self.time(&w.writer, now);
        try w.writer.print("{s}\n", .{keyword});
        for (self.codes.items, 0..) |c, i| {
            // An event holds no value to checkpoint.
            if (cat.vars[c.v].event) continue;
            src.dumpPlanes(cat.vars[c.v], c.last);
            try value(&w.writer, cat.vars[c.v], c.last, @intCast(i), as_x);
        }
        try w.writer.writeAll("$end\n");
        try self.put(io, w.written());
    }

    /// The variables whose value is not the one last dumped.
    fn changes(self: *Vcd, a: std.mem.Allocator, io: ?std.Io, cat: *const Catalog, src: anytype, now: u64) Failure!void {
        if (!self.on) return;
        var w: std.Io.Writer.Allocating = .init(a);
        // ponytail: every dumped variable is compared each dumped step; a changed
        // list fed by `store` replaces the scan when a design dumps thousands.
        var buf: std.ArrayList(u64) = .empty;
        for (self.codes.items, 0..) |*c, i| {
            // §18.2.2: "Events are dumped in the same format as scalars ...
            // the value ... is irrelevant", a marker of a trigger.
            if (cat.vars[c.v].event) {
                if (!c.fired) continue;
                c.fired = false;
                if (w.written().len == 0) try self.time(&w.writer, now);
                try w.writer.writeByte('1');
                try codeText(&w.writer, @intCast(i));
                try w.writer.writeByte('\n');
                continue;
            }
            try buf.resize(a, c.last.len);
            src.dumpPlanes(cat.vars[c.v], buf.items);
            if (std.mem.eql(u64, c.last, buf.items)) continue;
            if (w.written().len == 0) try self.time(&w.writer, now);
            @memcpy(c.last, buf.items);
            try value(&w.writer, cat.vars[c.v], c.last, @intCast(i), false);
        }
        try self.put(io, w.written());
    }
};

/// The source text of the task call whose name starts `text` at `start`,
/// through its closing parenthesis: `$dumpfile(fname)`.
pub fn callText(text: []const u8, start: u32) []const u8 {
    var depth: u32 = 0;
    var i: usize = start;
    var quoted = false;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '"' => quoted = !quoted,
        '\\' => i += @intFromBool(quoted),
        '(' => depth += @intFromBool(!quoted),
        ')' => if (!quoted) {
            depth -= 1;
            if (depth == 0) return text[start .. i + 1];
        },
        else => {},
    };
    return text[start..];
}

/// §18.2.3.1-§18.2.3.8's opening sections, shared with the extended VCD
/// (§18.4.1): `$date`, `$version` naming the task `call` that made the file,
/// and `$timescale` of the tick, 10^`finest` s.
pub fn preamble(w: *std.Io.Writer, io: std.Io, call: []const u8, finest: i32) std.Io.Writer.Error!void {
    const t = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s))) };
    const yd = t.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = t.getDaySeconds();
    try w.print("$date\n\t{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n$end\n", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    try w.print("$version\n\tVerA\n\t{s}\n$end\n", .{call});
    // Ticks are the precision (`Time.Scale`'s global), so the file's unit
    // is the precision: `time_number` 1, 10 or 100 of an SI unit.
    const units = [_][]const u8{ "fs", "ps", "ns", "us", "ms", "s" };
    const k: i32 = @divFloor(finest, 3);
    try w.print("$timescale {d}{s} $end\n", .{ std.math.pow(u32, 10, @intCast(finest - 3 * k)), units[@intCast(k + 5)] });
}

fn words(w: u32) u32 {
    return (w + 63) / 64;
}

/// §18.2.1 identifier codes, "composed of the printable characters ... from
/// ! to ~": code 0 is `!`, and a longer code counts on in base 94.
fn codeText(w: *std.Io.Writer, code: u32) std.Io.Writer.Error!void {
    var n = code;
    while (true) {
        try w.writeByte(@intCast('!' + n % 94));
        if (n < 94) return;
        n = n / 94 - 1;
    }
}

/// §18.2.2 one value change of `v`, whose planes are `p`: a scalar's value
/// and code with no space, a vector's `b` digits then one space, a real's
/// `r` and `%.16g`.
fn value(w: *std.Io.Writer, v: Var, p: []const u64, code: u32, as_x: bool) std.Io.Writer.Error!void {
    const lit: @import("kernels").Integer.Literal = .{ .width = v.width, .signed = false, .sized = true, .planes = @constCast(p) };
    if (v.real and !as_x) {
        var buf: [64]u8 = undefined;
        try w.print("r{s} ", .{g16(&buf, @bitCast(p[0]))});
    } else if (v.width == 1) {
        try w.writeByte(if (as_x) 'x' else bitChar(lit.bit(0)));
    } else {
        try w.writeByte('b');
        var i = v.width;
        if (as_x) i = 1;
        // Table 18-1: a leading digit the next one would extend to anyway is
        // dropped: 0 before 0 or 1, x before x, z before z.
        while (i > 1) : (i -= 1) {
            const top = lit.bit(i - 1);
            const next = lit.bit(i - 2);
            const redundant = if (top == .zero) next == .zero or next == .one else top != .one and top == next;
            if (!redundant) break;
        }
        while (i > 0) : (i -= 1) try w.writeByte(if (as_x) 'x' else bitChar(lit.bit(i - 1)));
        try w.writeByte(' ');
    }
    try codeText(w, code);
    try w.writeByte('\n');
}

/// §18.2.1 "A real number is dumped using a %.16g printf() format": C's
/// style e when the exponent is below -4 or at least 16, else style f with
/// 16 significant digits, trailing zeros and point removed either way.
fn g16(buf: *[64]u8, r: f64) []const u8 {
    if (std.math.isNan(r)) return "nan";
    if (std.math.isInf(r)) return if (r < 0) "-inf" else "inf";
    var sci_buf: [64]u8 = undefined;
    const sci = std.mem.print(&sci_buf, "{e:.15}", .{r}) catch unreachable;
    const e_at = std.mem.findScalar(u8, sci, 'e').?;
    const x = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
    if (x < -4 or x >= 16) {
        const mant = strip(sci[0..e_at]);
        return std.mem.print(buf, "{s}e{c}{d:0>2}", .{ mant, @as(u8, if (x < 0) '-' else '+'), @abs(x) }) catch unreachable;
    }
    return strip(std.mem.print(buf, "{d:.[1]}", .{ r, @as(usize, @intCast(15 - x)) }) catch unreachable);
}

/// `%g`'s removal of trailing fraction zeros and a trailing point.
fn strip(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '.') == null) return s;
    const t = std.mem.trimEnd(u8, s, "0");
    return if (t[t.len - 1] == '.') t[0 .. t.len - 1] else t;
}

test "§18.2.1 %.16g" {
    var buf: [64]u8 = undefined;
    for ([_]f64{ 1.5, -2.25e10, 0.25, 6.02e23, 1e16, 0.0, 1.0 / 3.0, 1e-5, 123456789012345678.0 }, [_][]const u8{ "1.5", "-22500000000", "0.25", "6.02e+23", "1e+16", "0", "0.3333333333333333", "1e-05", "1.234567890123457e+17" }) |r, want|
        try std.testing.expectEqualStrings(want, g16(&buf, r));
}

// ---- compile time -----------------------------------------------------------

/// Refuses a malformed §18.1 call before the run.
pub fn check(r: *Run, op: Op, args: []const Ast.ExprId, tok: u32) Error!void {
    for (args) |a| if (a == .none) return r.fail(tok, "the §18.1 dump tasks take no null arguments", .{});
    switch (op) {
        // §18.1.1: the filename is optional.
        .file => {
            if (args.len > 1) return r.fail(tok, "$dumpfile takes at most one filename", .{});
            for (args) |a| try compile.checkExpr(r, a);
        },
        .vars => if (args.len != 0) {
            try compile.checkExpr(r, args[0]);
            for (args[1..]) |a| _ = try target(r, a);
        },
        .limit => {
            if (args.len != 1) return r.fail(tok, "$dumplimit takes one file size", .{});
            try compile.checkExpr(r, args[0]);
        },
        .off, .on, .all, .flush => if (args.len != 0) return r.fail(tok, "$dumpoff, $dumpon, $dumpall and $dumpflush take no arguments", .{}),
    }
}

/// §18.1.2 `module_or_variable`: a module instance (the root by its module
/// name, or a downward path) or a variable, by slot.
pub fn target(r: *Run, e: Ast.ExprId) Error!Target {
    const ex = &r.file.exprs;
    const parts: []const Ast.StrId = switch (ex.tag(e)) {
        .ident => &.{ex.strOf(e)},
        .hier_ident => ex.nameParts(e),
        else => return r.exprFail(e, "$dumpvars names a module instance or a variable"), // else: A.8.x forms that name no scope or variable
    };
    var scope = r.instanceOf(r.scope);
    var first = true;
    for (parts, 0..) |p, i| {
        const last = i + 1 == parts.len;
        if (r.instances.get(.{ .scope = scope, .str = p })) |child| {
            scope = child;
        } else if (if (first) rootNamed(r, p) else null) |t| {
            scope = t;
        } else if (last) {
            const at = (if (parts.len == 1) r.lookup(scope, p) else r.names.get(.{ .scope = scope, .str = p })) orelse
                return r.exprFail(e, "$dumpvars names a module instance or a variable");
            return .{ .slot = at };
        } else return r.exprFail(e, "undeclared instance in a hierarchical reference");
        first = false;
    }
    return .{ .scope = scope };
}

/// The top-level module named `name`.
fn rootNamed(r: *const Run, name: Ast.StrId) ?u32 {
    for (r.roots) |t| if (r.scope_info.items[t].name == name) return t;
    return null;
}

// ---- the interpreter's half ---------------------------------------------------

/// `r`'s `Catalog`: `offs` gives each slot's first plane word (a native
/// executable's layout), or is empty.
pub fn catalog(r: *Run, a: std.mem.Allocator, offs: []const u32) Error!Catalog {
    const scopes = try a.alloc(Scope, r.scope_info.items.len);
    const var_start = try a.alloc(u32, scopes.len + 1);
    var vars: std.ArrayList(Var) = .empty;
    // §18.2.3.4 a static task's or function's frame is a scope of its own.
    const subs = try a.alloc(?*const Ast.Subroutine, scopes.len);
    @memset(subs, null);
    for (r.subs.items) |sub| if (sub.framed and !sub.decl.automatic) {
        subs[sub.frame.scope] = sub.decl;
    };
    for (r.scope_info.items, scopes, subs, 0..) |info, *sc, sub, s| {
        var line: std.Io.Writer.Allocating = .init(a);
        const kind = if (sub) |t| (if (t.is_function) "function" else "task") else if (info.lexical) "begin" else "module";
        try line.writer.print("$scope {s} {s}", .{ kind, r.file.str(info.name) });
        if (info.index) |i| try line.writer.print("[{d}]", .{i});
        try line.writer.writeAll(" $end\n");
        sc.* = .{ .line = line.written(), .parent = info.parent, .lexical = info.lexical, .child = sub != null or !(info.lexical and info.index == null) };
        var_start[s] = @intCast(vars.items.len);
        if (sub == null and info.lexical) continue;
        const m = &r.file.modules[info.def];
        // Exact: a subroutine's ports and variables, or a module's ports,
        // nets, variables and events.
        var decls: std.ArrayList(Ast.VarDecl) = try .initCapacity(a, if (sub) |t| t.ports.len + t.vars.len else m.vars.len);
        var names: std.ArrayList(Ast.StrId) = try .initCapacity(a, if (sub) |t| t.ports.len + t.vars.len else m.ports.len + m.nets.len + m.vars.len + m.events.len);
        var events: []const Ast.EventDecl = &.{};
        if (sub) |t| {
            for (t.ports) |p| decls.appendAssumeCapacity(p.v);
            decls.appendSliceAssumeCapacity(t.vars);
        } else {
            for (m.ports) |p| names.appendAssumeCapacity(p.name);
            for (m.nets) |n| names.appendAssumeCapacity(n.name);
            decls.appendSliceAssumeCapacity(m.vars);
            events = m.events;
        }
        for (decls.items) |d| names.appendAssumeCapacity(d.name);
        for (events) |event| names.appendAssumeCapacity(event.name);
        std.debug.assert(names.items.len == names.capacity);
        for (names.items, 0..) |name, i| {
            if (std.mem.findScalar(Ast.StrId, names.items[0..i], name) != null) continue;
            const at = r.names.get(.{ .scope = @intCast(s), .str = name }) orelse continue;
            if (r.arrays.contains(at) or r.params.contains(at)) continue;
            try vars.append(a, try variable(r, a, decls.items, name, at, if (offs.len == 0) 0 else offs[at]));
        }
    }
    var_start[scopes.len] = @intCast(vars.items.len);
    return .{ .scopes = scopes, .var_start = var_start, .vars = vars.items, .finest = r.finest };
}

/// §18.2.3.7 `$var var_type size identifier_code reference $end`.
fn variable(r: *Run, a: std.mem.Allocator, decls: []const Ast.VarDecl, name: Ast.StrId, at: u32, off: u32) Error!Var {
    const kind: []const u8 = if (r.events.contains(at)) "event" else if (r.net_of.get(at)) |n| switch (r.nets[n].kind) {
        // "a net of net type uwire shall have a variable type of wire"
        .uwire => "wire",
        .wreal => "real",
        .wire, .tri, .tri0, .tri1, .triand, .trior, .trireg, .wand, .wor, .supply0, .supply1 => @tagName(r.nets[n].kind),
    } else if (r.reals.contains(at)) "real" else for (decls) |x| {
        if (x.name == name) break switch (x.storage) {
            .reg => "reg",
            .time => "time",
            .variable => "integer",
        };
    } else "reg";
    const event = r.events.contains(at);
    const width = if (event) 1 else r.values[at].width;
    const head = try a.print("$var {s} {d} ", .{ kind, width });
    var tail: std.Io.Writer.Allocating = .init(a);
    try tail.writer.print(" {s}", .{r.file.str(name)});
    if (r.vec_ranges.get(at)) |range| try tail.writer.print(" [{d}:{d}]", .{ range.msb, range.lsb });
    try tail.writer.writeAll(" $end\n");
    return .{ .slot = at, .off = off, .width = width, .real = r.reals.contains(at), .event = event, .head = head, .tail = tail.written() };
}

/// The interpreter as `Vcd`'s `src`.
const Values = struct {
    r: *Run,
    /// Copies `v`'s current planes into `out`, which is exactly as long.
    pub fn dumpPlanes(self: Values, v: Var, out: []u64) void {
        @memcpy(out, self.r.values[v.slot].planes);
    }
    /// Marks `slot` dumped, so `store` requests the end-of-step section.
    pub fn dumpSlot(self: Values, slot: u32) void {
        self.r.watch[slot].insert(.vcd);
    }
};

fn catalogOf(r: *Run) Error!*const Catalog {
    if (r.vcd_catalog == null) r.vcd_catalog = try catalog(r, r.arena, &.{});
    return &r.vcd_catalog.?;
}

fn failed(r: *Run, e: Failure) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DumpvarsTime => r.fail(r.vcd.tok, message(error.DumpvarsTime), .{}),
        inline else => |f| r.fail(r.vcd.tok, comptime message(f), .{r.vcd.name}),
    };
}

/// The interpreter's run of one §18.1 task.
pub fn task(r: *Run, a: std.mem.Allocator, op: Op, args: []const Ast.ExprId, tok: u32) Error!void {
    const v = &r.vcd;
    switch (op) {
        .file => if (args.len == 1 and !v.started) {
            const name = try @import("system.zig").text(a, try evaluate.eval(r, a, args[0], 0));
            v.setFile(r.arena, name, callText(r.text, r.starts[tok])) catch |e| return failed(r, e);
        },
        .vars => {
            var levels: u32 = 0;
            const targets = try a.alloc(Target, if (args.len == 0) r.roots.len else args.len - 1);
            if (args.len == 0) {
                for (r.roots, targets) |s, *t| t.* = .{ .scope = s };
            } else {
                levels = std.math.lossyCast(u32, (try evaluate.eval(r, a, args[0], 0)).asInt() orelse 0);
                for (args[1..], targets) |e, *t| t.* = try target(r, e);
            }
            v.select(r.arena, r.scheduler.now, tok, levels, targets) catch |e| {
                if (e == error.DumpvarsTime) return r.fail(tok, message(error.DumpvarsTime), .{});
                return failed(r, e);
            };
            try waiters.requestVcd(r);
        },
        .limit => v.limit = std.math.lossyCast(u64, (try evaluate.eval(r, a, args[0], 0)).asInt() orelse 0),
        .flush, .off, .on, .all => v.control(a, r.io, try catalogOf(r), Values{ .r = r }, r.scheduler.now, op) catch |e| return failed(r, e),
    }
}

/// The end of a time step with dumped changes (`Vcd.tick`).
/// The step's `.vcd_tick` serves the four-state dump, once `$dumpvars`
/// selected it, and the extended one (`evcd.tick`).
pub fn tick(r: *Run, a: std.mem.Allocator) Error!void {
    r.vcd.pending = false;
    if (r.vcd.selected_at != null) r.vcd.tick(r.arena, a, r.io, try catalogOf(r), Values{ .r = r }, r.scheduler.now) catch |e| return failed(r, e);
    try @import("evcd.zig").tick(r, a);
}

/// §17.4.1 `$finish` ends the run before the step's `.vcd_tick` dispatches;
/// what that step changed is still part of the dump.
pub fn finish(r: *Run, a: std.mem.Allocator) Error!void {
    if (r.vcd.pending) try tick(r, a);
}

test "§18.2.1 %.16g at the edges of its two styles" {
    var buf: [64]u8 = undefined;
    // Each expected text is C's printf("%.16g") of the value: the style is
    // chosen by the exponent after rounding to 16 digits, so 9.999...e15
    // rounds up into style e.
    const cases = [_]struct { f64, []const u8 }{
        .{ -@as(f64, 0.0), "-0" },
        .{ @as(f64, 0.1) + 0.2, "0.3" },
        .{ 1e-4, "0.0001" },
        .{ 3.0000000000000004e-05, "3e-05" },
        .{ 1e15, "1000000000000000" },
        .{ 9007199254740992.0, "9007199254740992" },
        .{ 9.999999999999999e15, "1e+16" },
        .{ 1.5e-300, "1.5e-300" },
        .{ 123.456, "123.456" },
        .{ std.math.inf(f64), "inf" },
        .{ -std.math.inf(f64), "-inf" },
        .{ std.math.nan(f64), "nan" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], g16(&buf, c[0]));
}

/// Reads back an identifier code `codeText` wrote (least significant
/// character first): the inverse the codes' uniqueness is checked with.
fn codeValue(text: []const u8) u32 {
    var i = text.len - 1;
    var n: u32 = text[i] - '!';
    while (i != 0) {
        i -= 1;
        n = (text[i] - '!') + 94 * (n + 1);
    }
    return n;
}

test codeText {
    var buf: [16]u8 = undefined;
    // §18.2.1: the 94 printable characters from ! to ~, then two of them.
    const cases = [_]struct { u32, []const u8 }{
        .{ 0, "!" },
        .{ 1, "\"" },
        .{ 93, "~" },
        .{ 94, "!!" },
        .{ 95, "\"!" },
        .{ 187, "~!" },
        .{ 188, "!\"" },
        .{ 94 * 94 + 93, "~~" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try codeText(&w, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
    // Every code reads back as itself, so no two variables share one.
    for (0..20_000) |code| {
        var w: std.Io.Writer = .fixed(&buf);
        try codeText(&w, @intCast(code));
        try std.testing.expectEqual(@as(u32, @intCast(code)), codeValue(w.buffered()));
        for (w.buffered()) |ch| try std.testing.expect(ch >= '!' and ch <= '~');
    }
}

fn testLiteral(a: std.mem.Allocator, bits: []const u8) !@import("kernels").Integer.Literal {
    const v = try @import("net.zig").filled(a, @intCast(bits.len), false, .zero);
    for (bits, 0..) |c, i| @import("net.zig").setBit(v, @intCast(bits.len - 1 - i), switch (c) {
        '0' => .zero,
        '1' => .one,
        'x' => .x,
        else => .z,
    });
    return v;
}

test value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §18.2.1 Table 18-1: a vector drops a leading digit the next one left-
    // extends to anyway: 0 before 0 or 1, x before x, z before z. Never a
    // 1, and never a 0 before an x or z.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "0000", "b0 !\n" },
        .{ "0010", "b10 !\n" },
        .{ "1010", "b1010 !\n" },
        .{ "xx01", "bx01 !\n" },
        .{ "zzzz", "bz !\n" },
        .{ "0x10", "b0x10 !\n" },
        .{ "z", "z!\n" },
        .{ "1", "1!\n" },
    };
    for (cases) |c| {
        const v = try testLiteral(a, c[0]);
        var out: std.Io.Writer.Allocating = .init(a);
        try value(&out.writer, .{ .slot = 0, .width = v.width, .real = false, .head = "", .tail = "" }, v.planes, 0, false);
        try std.testing.expectEqualStrings(c[1], out.written());
    }
    // §18.2.3.11 `$dumpoff`'s x: a vector as one extended digit.
    {
        const v = try testLiteral(a, "1010");
        var out: std.Io.Writer.Allocating = .init(a);
        try value(&out.writer, .{ .slot = 0, .width = 4, .real = false, .head = "", .tail = "" }, v.planes, 95, true);
        try std.testing.expectEqualStrings("bx \"!\n", out.written());
    }
    // A real: `r`, its %.16g, a space.
    {
        const p = [2]u64{ @bitCast(@as(f64, 1.5)), 0 };
        var out: std.Io.Writer.Allocating = .init(a);
        try value(&out.writer, .{ .slot = 0, .width = 64, .real = true, .head = "", .tail = "" }, &p, 0, false);
        try std.testing.expectEqualStrings("r1.5 !\n", out.written());
    }
}

test callText {
    // The call through its closing parenthesis: parentheses inside a string
    // (escaped quote included) or nested in the argument do not end it.
    const text = "x = 1; $dumpfile(\"a(\\\")b.vcd\"); $dumpfile((n)); $dumpfile";
    const s1 = std.mem.find(u8, text, "$dumpfile(\"").?;
    try std.testing.expectEqualStrings("$dumpfile(\"a(\\\")b.vcd\")", callText(text, @intCast(s1)));
    const s2 = std.mem.find(u8, text, "$dumpfile((").?;
    try std.testing.expectEqualStrings("$dumpfile((n))", callText(text, @intCast(s2)));
    // An unterminated call is the rest of the text.
    const s3 = std.mem.findLast(u8, text, "$dumpfile").?;
    try std.testing.expectEqualStrings("$dumpfile", callText(text, @intCast(s3)));
}

test preamble {
    var buf: [64]u8 = undefined;
    // §18.2.3.6: `time_number` is 1, 10 or 100 of an SI unit, here the tick
    // 10^finest s.
    const cases = [_]struct { i32, []const u8 }{
        .{ -15, "1fs" },
        .{ -14, "10fs" },
        .{ -13, "100fs" },
        .{ -12, "1ps" },
        .{ -9, "1ns" },
        .{ -1, "100ms" },
        .{ 0, "1s" },
        .{ 1, "10s" },
        .{ 2, "100s" },
    };
    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try preamble(&out.writer, std.testing.io, "$dumpfile(\"d.vcd\")", c[0]);
        const text = out.written();
        try std.testing.expectEqualStrings(try std.mem.print(&buf, "$timescale {s} $end\n", .{c[1]}), text[std.mem.find(u8, text, "$timescale ").?..]);
        // §18.2.3.8: `$version` names the call that made the file.
        try std.testing.expect(std.mem.find(u8, text, "$version\n\tVerA\n\t$dumpfile(\"d.vcd\")\n$end\n") != null);
        try std.testing.expect(std.mem.startsWith(u8, text, "$date\n\t"));
    }
}

test "§18.1.2 every $dumpvars runs at one time, before the dump starts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: Vcd = .{};
    try v.select(a, 5, 0, 0, &.{.{ .scope = 0 }});
    // "levels applies ... and not to individual variables": a second call
    // at the same time adds a variable and leaves the scope's count.
    try v.select(a, 5, 0, 2, &.{.{ .slot = 7 }});
    try std.testing.expectEqual(@as(?u32, 0), v.scopes.get(0));
    try std.testing.expect(v.slots.contains(7));
    try std.testing.expectError(error.DumpvarsTime, v.select(a, 6, 0, 0, &.{}));
    v.started = true;
    try std.testing.expectError(error.DumpvarsTime, v.select(a, 5, 0, 0, &.{}));
}

test "§18.1.1 $dumpfile names the file until dumping begins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: Vcd = .{};
    try std.testing.expectEqualStrings("dump.vcd", v.name);
    // A name with an x or z bit is no name.
    try v.setFile(a, null, "$dumpfile(n)");
    try std.testing.expectEqualStrings("dump.vcd", v.name);
    try std.testing.expect(v.call == null);
    try v.setFile(a, "a.vcd", "$dumpfile(\"a.vcd\")");
    try std.testing.expectEqualStrings("a.vcd", v.name);
    v.started = true;
    try v.setFile(a, "b.vcd", "$dumpfile(\"b.vcd\")");
    try std.testing.expectEqualStrings("a.vcd", v.name);
}
