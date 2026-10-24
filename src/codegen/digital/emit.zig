//! An elaborated `Run` and its source -> the Zig root of its executable, whose
//! `main` prints what `vera --run` prints. Each process (IEEE 1364-2005 §9.9,
//! §6.1, §6.2.1) becomes one function, a labeled switch over the pcs it
//! reaches with `emit_expr`'s expressions, once per `rt.Phase` (`Code(two)`).
//! A construct that is not native refuses by name; the executable then embeds
//! the source and runs the interpreter (`rt.interpret`, `Program.fallback`).
//! Clauses: IEEE 1364-2005 §3.2, §4.8/§4.8.2, §5.1.10, §5.2/§5.2.1,
//! §6.1/§6.1.3, §7.6, §7.8.5, §7.9, §7.10.2, §7.12, §7.14, §9.2/§9.2.2,
//! §9.3/§9.3.2, §9.4.7, §9.5, §9.7.1/§9.7.2/§9.7.6/§9.7.7, §9.8.2, §10.2.1
//! to §10.3, §12.3.6, §13.2/§13.7.1, §15, §17.1 to §17.6, §18; VAMS §9.22
//! driver access (refused).
const std = @import("std");
const no_cold = root.for_emitter.net.no_cold;
const Front = @import("frontend");
const Ast = Front.Ast;
// The interpreter, whose elaborated `Run` this reads until B4.
const root = @import("sim").digital;
const Run = root.Run;
const compile = root.for_emitter.compile;
const evaluate = root.for_emitter.evaluate;
const display = root.for_emitter.display;
const fmt = @import("kernels").fmt;
const expr = @import("emit_expr.zig");
const plan = @import("plan.zig");
const vcd = root.for_emitter.vcd;
const Type = compile.Type;
/// `plan.Schedule`, which root.zig re-exports for `vera --schedule=`.
pub const Schedule = plan.Schedule;

/// What `vera --emit-exe design.v` was given: enough to run the source again.
const Embed = struct {
    /// The design's source text, before preprocessing.
    source: []const u8,
    /// The name diagnostics and `$finish` reports give the source.
    file_name: []const u8,
    /// `-I` directories, searched by `` `include ``.
    include_dirs: []const []const u8,
    /// `--std=`'s keyword set.
    language: Front.token.KeywordSet,
    /// §13.2.3 the library the source maps into.
    lib: []const u8 = "work",
    /// More sources, each with its own library (§13.2).
    more: []const root.Unit = &.{},
    /// §13.7.1 `-L`'s library search order; empty is the default order.
    search: []const []const u8 = &.{},
};

/// What `program` made: the executable's root text, native or not.
pub const Program = struct {
    /// The executable's root module.
    text: []const u8,
    /// Null when the design runs natively; else why it does not.
    fallback: ?[]const u8,
    /// `.auto`, native: why the executable is 4-state throughout; null
    /// when it carries both phases (`rt.auto`).
    four: ?Reason = null,
};

/// Which logic the executable computes: IEEE 1364's 4-state; `--two-state`'s,
/// where every x or z is 0 (`rt.logic.two`); or 4-state that turns 2-state
/// once no live x or z is left (`rt.auto`), which prints what 4-state prints.
pub const Logic = enum { auto, two, four };

/// Why a design keeps x or z meaning, and the token where it does.
const Reason = struct { why: []const u8, tok: ?u32 };

/// `Unsupported`: a construct is not native; `Emitter.why` names it, and
/// `program` falls back to the interpreter (`device` refuses).
pub const Error = error{ Unsupported, OutOfMemory };

/// The root module of `r`'s executable. `r` is read and its time-0 queue
/// drained, never run. Under `.two` a design where an x or z carries
/// meaning is refused; under `.auto` it is 4-state throughout (`Program.four`).
/// A refused design's root embeds `embed` and runs the interpreter. Every
/// returned slice is in `arena`.
pub fn program(arena: std.mem.Allocator, r: *Run, embed: Embed, schedule: Schedule, logic: Logic) std.mem.Allocator.Error!Program {
    return @import("base").deep_stack.runGuarded(0, programDeep, .{ arena, r, embed, schedule, logic });
}

fn programDeep(arena: std.mem.Allocator, r: *Run, embed: Embed, schedule: Schedule, logic: Logic) std.mem.Allocator.Error!Program {
    // Emitting compiles `r`, it does not run it: what it raises through `r`
    // is a compile error (#72).
    r.diag_stage = .lower;
    var e: Emitter = .{ .r = r, .arena = arena, .out = .init(arena), .two_state = logic == .two, .auto = logic == .auto };
    if (native(&e, embed.file_name, schedule)) |text| return .{ .text = text, .fallback = null, .four = e.four } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .text = try interpreted(arena, embed, e.why), .fallback = e.why },
    }
}

/// A device root, or why `r` cannot be one.
pub const Device = union(enum) { zig: []const u8, refused: []const u8 };

/// The contract device of `r`'s top module (`rt.Device`): the native
/// processes and tables, then one pin per port bit, 4-state. `r` is read and
/// its time-0 queue drained, never run.
pub fn device(arena: std.mem.Allocator, r: *Run, file_name: []const u8, schedule: Schedule) std.mem.Allocator.Error!Device {
    r.diag_stage = .lower; // compiled, never run: as in `programDeep` (#72)
    var e: Emitter = .{ .r = r, .arena = arena, .out = .init(arena), .device = true };
    // `rt` reads these from the root module, which in a host is the host's.
    for (r.code.items) |ins| if (ins == .override_on) return .{ .refused = "a §9.3 procedural continuous assignment (assign or force)" };
    // ponytail: rt resolves switches, but no host test drives a device's
    // pins through one; open this with a vdev_host case that does.
    if (r.trans.len != 0) return .{ .refused = "a §7.6 pass switch" };
    if (native(&e, file_name, schedule)) |text| return .{ .zig = text } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .refused = e.why },
    }
}

/// The contract decls of a device root (`rt.Device`), after the design: its
/// top module's ports in declaration order, each bit a pin, a vector's from
/// its left index to its right. `U` is an `enum(u8)` up to 256 pins and as
/// wide as the pin count needs past them; the masks are `contract.MaskOf`.
fn deviceRoot(self: *Emitter) Error!void {
    const r = self.r;
    const m = &r.file.modules[r.scope_info.items[0].def];
    var names: std.Io.Writer.Allocating = .init(self.arena);
    var pins: std.Io.Writer.Allocating = .init(self.arena);
    var n: u32 = 0;
    for (m.ports) |p| {
        const out = switch (p.direction) {
            .input => false,
            .output => true,
            .inout, .unspecified => return self.refuse("an inout port: the analog side would drive a §7.9 resolved net"),
        };
        const at = r.names.get(.{ .scope = 0, .str = p.name }) orelse return self.refuse("a port with no net or variable behind it");
        if (r.reals.contains(at)) return self.refuse("a real port");
        for (m.vars) |v| if (v.name == p.name and v.storage != .reg) return self.refuse("an integer or time port");
        const w = self.slotWidth(at);
        const vr = expr.vecRange(r, at, w);
        const scalar = w == 1 and !r.vec_ranges.contains(at);
        var i = vr.msb;
        while (true) : (i = if (vr.msb >= vr.lsb) i - 1 else i + 1) {
            // Not a VerA cap: a contract mask is one integer with a bit per
            // pin (`contract.MaskOf`), and Zig's widest integer is u65535.
            if (n == std.math.maxInt(u16)) return self.refuse("more than 65535 pins (a contract mask is one u65535)");
            const name = if (scalar) r.file.str(p.name) else try self.arena.print("{s}[{d}]", .{ r.file.str(p.name), i });
            names.writer.print(" {f},", .{std.zig.fmtId(name)}) catch return error.OutOfMemory;
            pins.writer.print("\n        .{{ .out = {}, .slot = {d}, .off = {d}, .bit = {d} }},", .{ out, at, self.off[at], @abs(i - vr.lsb) }) catch return error.OutOfMemory;
            n += 1;
            if (i == vr.lsb) break;
        }
    }
    // No pins: Zig 0.17 refuses an empty exhaustive `enum(u8)`.
    const members = if (n == 0) " _," else names.written();
    const tag_bits = @max(8, std.math.log2_int_ceil(u32, @max(n, 1)));
    try self.print(
        \\/// The VerA release that generated this device (`contract.vera_version`).
        \\pub const vera_version = "{s}";
        \\pub const U = enum(u{d}) {{{s} }};
        \\pub const num_ports: usize = {d};
        \\const Dev = rt.Device(.{{ .U = U, .design = &design, .dispatch = Code(false).dispatch, .units = {d}, .pins = &.{{{s}
        \\}} }});
        \\pub const Model = Dev.Model;
        \\pub const Instance = Dev.Instance;
        \\pub const State = Dev.State;
        \\pub const state_class = Dev.state_class;
        \\pub const deriv_reads = Dev.deriv_reads;
        \\pub const ddx_reads = Dev.ddx_reads;
        \\pub const jac_pattern = Dev.jac_pattern;
        \\pub const eval = Dev.eval;
        \\pub const initState = Dev.initState;
        \\pub const updateState = Dev.updateState;
        \\pub const stateCtl = Dev.stateCtl;
        \\pub const pendingBreakpoint = Dev.pendingBreakpoint;
        \\
        \\comptime {{
        \\    @import("contract").validate(@This());
        \\}}
        \\
    , .{ @import("contract").vera_version, tag_bits, members, n, r.finest, pins.written() });
}

fn interpreted(arena: std.mem.Allocator, embed: Embed, why: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print(
        \\// GENERATED BY VerA — DO NOT EDIT. {f}
        \\// Not native ({s}): the embedded source runs through the interpreter.
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) u8 {{
        \\    return @import("sim").rt.interpret(init, .{{ .file_name = "{f}", .language = .{t}, .include_dirs = &.{{
    , .{ std.zig.fmtString(embed.file_name), why, std.zig.fmtString(embed.file_name), embed.language }) catch return error.OutOfMemory;
    for (embed.include_dirs) |d| w.print(" \"{f}\",", .{std.zig.fmtString(d)}) catch return error.OutOfMemory;
    w.print(" }}, .lib = \"{f}\", .more = &.{{", .{std.zig.fmtString(embed.lib)}) catch return error.OutOfMemory;
    for (embed.more) |u| w.print(" .{{ .name = \"{f}\", .text = \"{f}\", .lib = \"{f}\" }},", .{ std.zig.fmtString(u.name), std.zig.fmtString(u.text), std.zig.fmtString(u.lib) }) catch return error.OutOfMemory;
    w.writeAll(" }, .search = &.{") catch return error.OutOfMemory;
    for (embed.search) |l| w.print(" \"{f}\",", .{std.zig.fmtString(l)}) catch return error.OutOfMemory;
    w.print(" }} }}, \"{f}\");\n}}\n", .{std.zig.fmtString(embed.source)}) catch return error.OutOfMemory;
    return out.written();
}

/// One emission's state: the `Run` it reads (never runs), the text so far
/// in `out`, and the layout and bookkeeping tables the processes and the
/// trailing `rt.Design` share. Everything is `arena`'s; one `Emitter` per
/// `program`/`device` call.
pub const Emitter = struct {
    r: *Run,
    arena: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    /// Why the design is not native, once something refused.
    why: []const u8 = "",
    labels: u32 = 0,
    /// Each slot's first word in `rt.State`'s planes.
    off: []const u32 = &.{},
    /// `plan.Plan.watched` and `plan.Plan.reach`.
    watched: []const bool = &.{},
    reach: []const plan.Reach = &.{},
    /// The process being emitted.
    role: plan.Role = .general,
    /// `Logic.two` and `Logic.auto` (`program`); under `auto`, the first
    /// reason the design keeps x or z meaning.
    two_state: bool = false,
    auto: bool = false,
    four: ?Reason = null,
    /// Emitting a contract device (`device`), not an executable.
    device: bool = false,
    /// The subroutines a call reached (§10), each emitted once as
    /// `fn proc<entry>` after the processes.
    subs_todo: std.ArrayList(u32) = .empty,
    sub_done: []bool = &.{},
    /// The tasks whose out-of-line body a `.call_timed` reached (§10.2.3),
    /// each a process of its own whose activations `rt.State.ctx` tells
    /// apart.
    timed: std.ArrayList(u32) = .empty,
    /// Indexed named-event controls: an emitted selector reads its lexical
    /// scope when an array element occurs, not when the process suspends.
    event_selects: std.ArrayList(struct { e: Ast.ExprId, scope: u32 }) = .empty,
    /// Emitting a subroutine body: every step first checks whether a
    /// `disable` is unwinding it (§10.3).
    in_sub: bool = false,
    /// The pc of each `$strobe`/`$monitor` site, in `rt.show_base` order.
    shows: std.ArrayList(u32) = .empty,
    /// Each intra-assignment cell's first word, past the slots' (§9.7.7).
    cells: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Plane words so far: the slots', then the cells'.
    total: u32 = 0,
    /// Plane words of the slots alone.
    slot_words: u32 = 0,
    /// Per first pc of a `disable` target (a named block, an inlined task
    /// copy), the pcs its process resumes at once disabled (§10.3).
    block_ends: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    /// Per `Run` net and driver, its row in `rt.net`'s tables; null for a
    /// net that is its one plain driver's copy (`plainDriver`).
    net_ix: []?u32 = &.{},
    drv_ix: []?u32 = &.{},
    /// The `Run` nets and drivers of those rows, in row order.
    rt_nets: std.ArrayList(u32) = .empty,
    rt_drivers: std.ArrayList(u32) = .empty,
    /// §18.3 each `$dumpports` call (`rt.evcd.File`), by the pc it is at.
    port_files: std.ArrayList(PortFile) = .empty,
    /// §9.3.2 each distinct forced select's row in `rt.State.parts`, by
    /// slot and bits, and per slot its first row (`rt.Design.part_start`):
    /// `forcedParts`.
    parts: std.AutoHashMapUnmanaged(struct { slot: u32, bits: compile.Bits }, u32) = .empty,
    part_start: []const u32 = &.{},
    /// Per slot: some `force` holds a select of it (§9.3.2), so its net
    /// resolves in `rt.net`, whose `store` keeps the forced bits.
    select_forced: []const bool = &.{},
    /// Per settle node: `pureNode` of its pc.
    pure_nodes: []const bool = &.{},

    /// Appends formatted Zig text to `out`; a writer failure is OOM.
    pub fn print(self: *Emitter, comptime f: []const u8, args: anytype) Error!void {
        self.out.writer.print(f, args) catch return error.OutOfMemory;
    }

    /// Records `why` (static text) as the reason the design is not native
    /// and returns `error.Unsupported` for the caller to propagate.
    pub fn refuse(self: *Emitter, why: []const u8) error{Unsupported} {
        self.why = why;
        return error.Unsupported;
    }

    /// Whether `xMeaning` and `keepFour` can do anything: skip their
    /// checks otherwise.
    pub fn caresX(self: *const Emitter) bool {
        return self.two_state or self.auto;
    }

    /// An x or z carries meaning at token `tok`: `--two-state` refuses the
    /// design, `auto` keeps it 4-state.
    pub fn xMeaning(self: *Emitter, why: []const u8, tok: ?u32) Error!void {
        if (self.two_state) return self.refuse(why);
        self.keepFour(why, tok);
    }

    /// Under `auto`, the design stays 4-state throughout; the first reason
    /// is the one kept.
    pub fn keepFour(self: *Emitter, why: []const u8, tok: ?u32) void {
        if (self.auto and self.four == null) self.four = .{ .why = why, .tok = tok };
    }

    /// A fresh number for a block label or a capture.
    pub fn label(self: *Emitter) u32 {
        self.labels += 1;
        return self.labels;
    }

    /// Refuses a real: a `logic.T` holds only integral values.
    pub fn fits(self: *Emitter, t: Type) Error!void {
        if (t.real) return self.refuse("a real value");
    }

    /// `M.get` (or `M.getw`) of slot `at`'s value.
    pub fn get(self: *Emitter, at: u32) Error!void {
        const w = self.r.values[at].width;
        if (w <= 64) return self.print("M.get(s, {d})", .{self.off[at]});
        try self.print("M.getw(s, {d}, {d})", .{ self.off[at], words(w) });
    }

    /// The call that stores into slot `at`, up to its value: `M.nba` (or
    /// `M.nbaAfter`), or `M.put`, or `M.set` when nothing can wait on the slot.
    pub fn store(self: *Emitter, at: u32, how: How) Error!void {
        // §4.8 a real changes when its value does, not its bits.
        if (self.r.reals.contains(at)) {
            try realStoreCall(self, how);
            return self.print("{d}, {d}, ", .{ at, self.off[at] });
        }
        if (how == .blocking and !self.watched[at]) return self.print("try M.set(s, {d}, ", .{self.off[at]});
        try storeCall(self, how, self.reach[at]);
        try self.print("{d}, {d}, ", .{ at, self.off[at] });
    }

    /// `store` of the element `a<lb>` of the array whose first element is
    /// slot `base`.
    fn storeElement(self: *Emitter, base: u32, lb: u32, how: How) Error!void {
        const off = .{ self.off[base], lb, base, words(self.r.values[base].width) };
        if (self.r.reals.contains(base)) {
            try realStoreCall(self, how);
            return self.print("a{d}, {d} + (a{d} - {d}) * {d}, ", .{lb} ++ off);
        }
        const count = self.r.arrays.get(base).?.count;
        const watched = std.mem.findScalar(bool, self.watched[base..][0..count], true) != null;
        if (how == .blocking and !watched) return self.print("try M.set(s, {d} + (a{d} - {d}) * {d}, ", off);
        var wakes: plan.Reach = .{};
        for (self.reach[base..][0..count]) |x| wakes = @bitCast(@as(u8, @bitCast(wakes)) | @as(u8, @bitCast(x)));
        try storeCall(self, how, wakes);
        try self.print("a{d}, {d} + (a{d} - {d}) * {d}, ", .{lb} ++ off);
    }

    /// The slot `e` names in the current scope (`Run.slot`).
    pub fn slot(self: *Emitter, e: Ast.ExprId) Error!u32 {
        return self.r.slot(e) catch return self.refuse("a name the engine resolves only at run time");
    }

    /// Slot `at`'s first word; past the last slot, the end of theirs.
    fn slotOff(self: *const Emitter, at: u32) u32 {
        return if (at < self.off.len) self.off[at] else self.slot_words;
    }

    /// Slot `at`'s width in bits (a real's is 64).
    pub fn slotWidth(self: *const Emitter, at: u32) u32 {
        return self.r.values[at].width;
    }

    /// Does `e` name an element of an unpacked array (`Run.indexedArray`)?
    pub fn element(self: *Emitter, e: Ast.ExprId) Error!bool {
        return (self.r.indexedArray(e) catch return self.refuse("an array reference the engine resolves only at run time")) != null;
    }
};

/// How an assignment stores (§9.2): now, or as a nonblocking update of
/// this step or `delay` later.
pub const How = union(enum) { blocking, nba, nba_after: Ast.ExprId };

/// §4.8 real deposits compare numeric values at arrival, including NBA
/// updates. Keep their type in the queue until then (§9.2.2).
fn realStoreCall(self: *Emitter, how: How) Error!void {
    switch (how) {
        .blocking => try self.print("try s.putReal(", .{}),
        .nba => try self.print("try s.nbaReal(", .{}),
        .nba_after => |d| {
            try self.print("try s.nbaRealAfter(", .{});
            try delay(self, d);
            try self.print(", ", .{});
        },
    }
}

fn storeCall(self: *Emitter, how: How, wakes: plan.Reach) Error!void {
    switch (how) {
        .blocking => try self.print("try M.put(s, {f}, ", .{fmtReach(wakes)}),
        .nba => try self.print("try M.nba(s, {f}, ", .{fmtReach(wakes)}),
        .nba_after => |d| {
            try self.print("try M.nbaAfter(s, {f}, ", .{fmtReach(wakes)});
            try delay(self, d);
            try self.print(", ", .{});
        },
    }
}

/// `wakes` as the `rt.Reach` literal of the fields it sets.
fn fmtReach(wakes: plan.Reach) std.fmt.Alt(plan.Reach, reachText) {
    return .{ .data = wakes };
}

fn reachText(wakes: plan.Reach, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll(".{");
    inline for (.{ "fan", "comb", "watch", "terms", "mon", "dump", "path" }) |f| if (@field(wakes, f)) try out.writeAll(" ." ++ f ++ " = true,");
    try out.writeAll(" }");
}

/// A right-hand side: an expression, a value already stored at word `off`
/// with type `ty` (§9.7.7), or a formal captured before restoring its
/// caller's automatic frame (§10.2.2, §10.2.3).
/// `part` is bits `lo` up of the `total`-bit local `cat<label>`, one operand's
/// share of a concatenation lvalue's value.
const Rhs = union(enum) {
    expr: Ast.ExprId,
    stored: struct { off: u32, ty: Type },
    captured: struct { call: u32, port: usize, ty: Type },
    /// A procedural RHS evaluated before resolving an indexed target,
    /// including when that target ultimately names no storage (§9.2).
    evaluated: struct { label: u32, ty: Type },
    part: struct { label: u32, lo: u32, total: u32 },
};

/// An already evaluated right-hand side, before assignment conversion.
fn rhsValue(self: *Emitter, rhs: Rhs) Error!void {
    switch (rhs) {
        .expr, .part => unreachable, // `rhsFor` emits expressions and concatenation slices directly.
        .stored => |v| if (v.ty.width <= 64)
            try self.print("M.get(s, {d})", .{v.off})
        else
            try self.print("M.getw(s, {d}, {d})", .{ v.off, words(v.ty.width) }),
        .captured => |v| try self.print("o{d}_{d}", .{ v.call, v.port }),
        .evaluated => |v| try self.print("v{d}", .{v.label}),
    }
}

/// `rhs` in the type `target` gives it (`evaluate.evalFor`, `evaluate.convertSlot`).
fn rhsFor(self: *Emitter, rhs: Rhs, target: Type) Error!void {
    const ty = switch (rhs) {
        .expr => |e| return expr.assigned(self, e, target),
        .stored => |v| v.ty,
        .captured => |v| v.ty,
        .evaluated => |v| v.ty,
        .part => |p| return self.print("L.part(cat{d}, {d}, {d}, {d})", .{ p.label, p.lo, target.width, p.total }),
    };
    // `evaluate.convertValue`, §4.8.2 between a real and an integer.
    if (ty.real and target.real) return rhsValue(self, rhs);
    if (target.real) {
        try self.print("L.realBits(L.toReal(", .{});
        try rhsValue(self, rhs);
        return self.print(", {d}, {}))", .{ ty.width, ty.signed });
    }
    if (ty.real) {
        try self.print("L.ofRealTo(L.real(", .{});
        try rhsValue(self, rhs);
        return self.print("), {d})", .{target.width});
    }
    try self.print("L.rs(", .{});
    try rhsValue(self, rhs);
    try self.print(", {d}, {d}, {})", .{ ty.width, target.width, ty.signed });
}

/// `exec.callSync` of subroutine `idx` with `args`, as statements in the
/// caller's scope: the inputs read before anything of the callee's changes,
/// an automatic frame set aside and made x, the body, the outputs copied
/// back unless a `disable` ended it (§10.2.2, §10.2.3, §10.3). A function's
/// value is left in `r<lb>`.
pub fn call(self: *Emitter, idx: u32, args: []const Ast.ExprId, lb: u32) Error!void {
    const r = self.r;
    const sub = r.subs.items[idx];
    const f = sub.frame;
    if (!self.sub_done[idx]) {
        self.sub_done[idx] = true;
        try self.subs_todo.append(self.arena, idx);
    }
    for (sub.decl.ports, args, f.ports, 0..) |p, arg, at, i| if (p.direction != .output) {
        try self.print("            const i{d}_{d} = ", .{ lb, i });
        try expr.assigned(self, arg, self.r.slotType(at));
        try self.print(";\n", .{});
    };
    const lo = self.slotOff(f.first);
    try self.print("            try s.enter({d}, {d}, ", .{ idx, lo });
    if (sub.decl.automatic) try self.print("&fill{d});\n", .{idx}) else try self.print("&.{{}});\n", .{});
    for (sub.decl.ports, f.ports, 0..) |p, at, i| if (p.direction != .output)
        try self.print("            try M.set(s, {d}, i{d}_{d}, {f});\n", .{ self.off[at], lb, i, full(self.slotWidth(at)) });
    try self.print("            try proc{d}(s, {d});\n", .{ sub.entry, sub.entry });
    if (sub.decl.is_function) {
        try self.print("            const r{d} = ", .{lb});
        try self.get(f.result);
        try self.print(";\n", .{});
    }
    var outs = false;
    for (sub.decl.ports) |p| outs = outs or p.direction != .input;
    if (outs) {
        // `leave` restores recursive caller locals and can finish a disable;
        // preserve both the output values and whether they may be copied.
        try self.print("            const copy{d} = s.unwind == null;\n", .{lb});
        for (sub.decl.ports, f.ports, 0..) |p, at, i| if (p.direction != .input) {
            try self.print("            const o{d}_{d} = ", .{ lb, i });
            try self.get(at);
            try self.print(";\n", .{});
        };
    }
    try self.print("            s.leave({d}, {d}, {d});\n", .{ idx, lo, if (sub.decl.automatic) self.slotOff(f.first + f.count) - lo else 0 });
    if (outs) {
        try self.print("            if (copy{d}) {{\n", .{lb});
        for (sub.decl.ports, args, f.ports, 0..) |p, arg, at, i| if (p.direction != .input)
            try assignment(self, arg, .{ .captured = .{ .call = lb, .port = i, .ty = self.r.slotType(at) } }, .blocking);
        try self.print("            }}\n", .{});
    }
}

/// `const <name><idx>`: automatic frame `f`'s fresh value, plane word by
/// word. §§10.2.3, 4.8: integral automatic storage starts x, real zero.
fn fillTable(self: *Emitter, name: []const u8, idx: u32, f: root.Frame) Error!void {
    const r = self.r;
    try self.print("const {s}{d} = [_]u64{{", .{ name, idx });
    for (r.values[f.first..][0..f.count], f.first..) |v, at| for (0..words(v.width)) |j| {
        const top = if (j + 1 == words(v.width)) expr.maskOf(v.width - 64 * @as(u32, @intCast(j))) else std.math.maxInt(u64);
        try self.print(" 0x{x},", .{if (self.two_state or r.reals.contains(@intCast(at))) 0 else top});
    };
    try self.print(" }};\n\n", .{});
}

/// The 64-bit plane words a `w`-bit value occupies in `rt.State`.
pub fn words(w: u32) u32 {
    return (w + 63) / 64;
}

/// Every bit of a `w`-bit slot, as `rt.State.put`'s mask.
pub fn full(w: u32) std.fmt.Alt(u32, fullText) {
    return .{ .data = w };
}

fn fullText(w: u32, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (w <= 64) return out.print("0x{x}", .{expr.maskOf(w)});
    try out.print("L.full({d})", .{w});
}

/// The native root, or `error.Unsupported` with `self.why` set.
fn native(self: *Emitter, file_name: []const u8, schedule: Schedule) Error![]const u8 {
    const r = self.r;
    // `rt` keeps a driver's delay as the constant ticks `Driver.delay` holds.
    if (r.driver_delays.count() != 0) return self.refuse("A.2.2.3 a continuous assignment or gate delay that reads a variable");
    const off = try self.arena.alloc(u32, r.values.len);
    var total: u32 = 0;
    for (r.values, off) |v, *o| {
        o.* = total;
        total += words(v.width);
    }
    self.off = off;
    self.slot_words = total;
    self.total = total;
    self.sub_done = try self.arena.alloc(bool, r.subs.items.len);
    @memset(self.sub_done, false);
    const forced = try self.arena.alloc(bool, r.values.len);
    @memset(forced, false);
    for (r.code.items) |ins| if (ins == .override_on) if (ins.override_on.bits != null) {
        forced[ins.override_on.slot] = true;
    };
    self.select_forced = forced;
    for (r.code.items) |ins| switch (ins) {
        .disable_block => |b| try blockEnd(self, b.start, b.end),
        .disable_task => |idx| for (r.subs.items[idx].ranges.items) |rg| try blockEnd(self, rg.start, rg.end),
        else => {}, // else: only a `disable` resumes a process somewhere it did not suspend
    };
    if (r.drv.watched.items.len != 0) return self.refuse("VAMS §9.22 driver access");
    // `rt` evaluates no timing check; the interpreter does (`tchk.zig`).
    if (r.tchks.items.len != 0) return self.refuse("IEEE 1364-2005 §15 timing checks");
    // §7.6: what a switch passes is a strength, which an x or z carries.
    if (r.trans.len != 0) try self.xMeaning("a §7.6 pass switch", null);
    try portDumps(self);
    try resolvedNets(self);
    // The time-0 queue in `Run.pending` order: every driver, declaration
    // assignment and process, as the pc it starts at.
    var order: std.ArrayList(u32) = .empty;
    while (r.scheduler.next()) |ev| switch (r.pending.items[ev.payload].item) {
        .run_process => |pc| try order.append(self.arena, pc),
        .@"resume", .write, .strobe, .monitor_tick, .vcd_tick, .tran_switch, .drive, .net_update, .decay, .a2d, .analog_point, .tchk_expiry => return self.refuse("an event queued at elaboration"),
    };

    try self.print(
        \\// GENERATED BY VerA — DO NOT EDIT. {f}
        \\const std = @import("std");
        \\const rt = @import("sim").rt;
        \\const L = rt.logic;
        \\const S = rt.State;
        \\
    , .{std.zig.fmtString(file_name)});
    if (self.two_state) try self.print("pub const vera_two_state = true;\n", .{});
    for (r.code.items) |ins| if (ins == .override_on) {
        try self.print("pub const vera_overrides = true;\n", .{});
        try forcedParts(self);
        break;
    };
    if (r.budget != root.max_events_per_tick) try self.print("pub const vera_event_budget: u64 = {d};\n", .{r.budget});
    // Every function of the design, once per phase (`rt.Phase`): `main`
    // names `Code(true)` only when it runs both, and Zig compiles only what
    // is named.
    const decls_at = self.out.written().len;
    try self.print("\nfn Code(comptime two: bool) type {{\nreturn struct {{\nconst M = rt.Phase(two);\n\n", .{});
    const seen = try self.arena.alloc(bool, r.code.items.len);
    @memset(seen, false);
    var procs: std.ArrayList(plan.Proc) = .empty;
    for (order.items) |entry| {
        if (seen[entry]) continue;
        try procs.append(self.arena, .{ .entry = entry, .pcs = try reach(self, entry, seen) });
    }
    var next_timed: usize = 0;
    while (next_timed < self.timed.items.len) : (next_timed += 1) {
        const entry = r.subs.items[self.timed.items[next_timed]].body.?.entry;
        if (!seen[entry]) try procs.append(self.arena, .{ .entry = entry, .pcs = try reach(self, entry, seen) });
    }
    const activations = self.timed.items.len != 0;
    if (activations) try insert(self, decls_at, "pub const vera_activations = true;\n");
    const p = try plan.build(self, procs.items, schedule);
    self.watched = p.watched;
    self.reach = p.reach;
    const pure_nodes = try self.arena.alloc(bool, p.node_pc.len);
    for (pure_nodes, p.node_pc) |*x, pc| x.* = pureNode(self, pc);
    self.pure_nodes = pure_nodes;
    // `fn proc<pc>` of every pc, so a dispatch is one indexed call.
    const entry_of = try self.arena.alloc(?u32, r.code.items.len);
    @memset(entry_of, null);
    for (procs.items) |pr| {
        self.role = pr.role;
        try process(self, pr.pcs);
        for (pr.pcs) |pc| entry_of[pc] = pr.pcs[0];
    }
    // Selector expressions can call HDL functions. Emit them before the
    // subroutine worklist so those functions are emitted as well.
    try eventSelectors(self);
    // §14.2.4 the module path conditions `rt.net` evaluates (`netTables`).
    try pathConds(self);
    // The subroutines the processes call, and those they call in turn. A
    // body is reached only through a call, which runs it to completion.
    self.role = .general;
    self.in_sub = true;
    var next_sub: usize = 0;
    while (next_sub < self.subs_todo.items.len) : (next_sub += 1) {
        const idx = self.subs_todo.items[next_sub];
        const sub = r.subs.items[idx];
        const pcs = try reach(self, sub.entry, seen);
        try process(self, pcs);
        for (pcs) |pc| entry_of[pc] = pcs[0];
        if (!sub.decl.automatic) continue;
        self.keepFour("an automatic task or function, whose storage is x at every call (§10.2.3)", null);
        try fillTable(self, "fill", idx, sub.frame);
    }
    self.in_sub = false;
    // §10.2.3 an automatic timed body's fresh frame, as `fill<idx>` is a
    // synchronous one's.
    for (self.timed.items) |idx| {
        const sub = r.subs.items[idx];
        if (!sub.decl.automatic) continue;
        self.keepFour("an automatic task or function, whose storage is x at every call (§10.2.3)", null);
        try fillTable(self, "tfill", idx, sub.body.?.frame);
    }
    try emitShows(self);

    try self.print("fn none(_: *S, _: u32) rt.Error!void {{\n    unreachable;\n}}\n\n", .{});
    // A pure node's process runs only in the time-0 queue, which the
    // 2-state phase never sees (`rt.auto`): that phase leaves it uncompiled.
    const time0 = try self.arena.alloc(bool, r.code.items.len);
    @memset(time0, false);
    if (self.auto) for (procs.items) |pr| if (pr.role == .comb and r.code.items[pr.entry] == .continuous and self.pure_nodes[pr.role.comb]) {
        time0[pr.entry] = true;
    };
    try self.print("const procs = [_]*const fn (*S, u32) rt.Error!void{{", .{});
    for (entry_of) |t| if (t) |lo| {
        if (time0[lo]) try self.print(" if (two) none else proc{d},", .{lo}) else try self.print(" proc{d},", .{lo});
    } else try self.print(" none,", .{});
    try self.print(" }};\n\n", .{});
    try self.print(
        \\pub fn dispatch(s: *S, pc: u32) rt.Error!void {{
        \\    if (pc < rt.show_base) {s}
        \\
    , .{if (entry_of.len == 0) "unreachable;" else if (activations)
        // §10.2.3 a timed call or return continues in another function at
        // once: one after another here, not nested on the stack.
        "{\n        try procs[pc](s, pc);\n        while (s.jump) |j| {\n            s.jump = null;\n            try procs[j](s, j);\n        }\n        return;\n    }"
    else
        "return procs[pc](s, pc);"});
    if (p.node_pc.len != 0) try self.print("    if (pc == rt.settle_pc) return settle(s.view());\n", .{});
    try self.print("    return show(s, pc - rt.show_base);\n}}\n\n", .{});
    // The settle event: the nodes in topological order, 64 to a dirty word,
    // each word a function of its own, since Zig's compile time grows faster
    // than a function's size. A word gets the view's fields and rebuilds it:
    // passed whole, the view is read through a pointer again after every store.
    if (p.node_pc.len != 0) {
        try self.print("fn settle(s: rt.View) rt.Error!void {{\n", .{});
        for (0..(p.node_pc.len + 63) / 64) |w| try self.print("    if (s.dirty[{d}] != 0) try @call(.never_inline, settle{d}, .{{ s.s, s.v, s.x, s.dirty }});\n", .{ w, w });
        try self.print("    s.s.settle = .idle;\n}}\n\n", .{});
        var lo: usize = 0;
        while (lo < p.node_pc.len) : (lo += 64) {
            try self.print("fn settle{d}(st: *S, v: [*]u64, x: [*]u64, dirty: [*]u64) rt.Error!void {{\n    @setEvalBranchQuota(1 << 30);\n", .{lo / 64});
            try self.print("    const s: rt.View = .{{ .s = st, .v = v, .x = x, .dirty = dirty }};\n", .{});
            for (p.node_pc[lo..@min(lo + 64, p.node_pc.len)], lo..) |pc, n| try settleNode(self, p, pc, @intCast(n), entry_of[pc].?);
            try self.print("    s.dirty[{d}] = 0;\n}}\n\n", .{lo / 64});
        }
        for (p.node_pc, self.pure_nodes, 0..) |pc, pure_node, n| if (pure_node) try nodeValue(self, pc, @intCast(n));
    }

    try self.print("}};\n}}\n\n", .{});
    if (!advances(r)) self.keepFour("nothing delays, so the run never leaves time 0", null);
    const two_phase = self.auto and self.four == null;
    // A suspension may survive the 4 -> 2 state transition. Its selector
    // must use the phase of the occurrence, not the phase that armed it.
    for (self.event_selects.items, 0..) |_, i| {
        try self.print("fn selectedEvent{d}(s: *S) rt.Error!?u32 {{\n", .{i});
        if (two_phase) try self.print("    if (s.two) return Code(true).eventSelect{d}(s);\n", .{i});
        try self.print("    return Code(false).eventSelect{d}(s);\n}}\n\n", .{i});
    }
    // Under `--two-state` an x or z initial value (§3.2) is 0. The
    // intra-assignment cells follow the slots; each is written before it
    // is read.
    try self.print("const design: rt.Design = .{{\n    .v = &.{{", .{});
    for (r.values) |v| for (v.values()[0..words(v.width)], v.unknowns()[0..words(v.width)]) |x, u|
        try self.print(" 0x{x},", .{if (self.two_state) x & ~u else x});
    for (self.slot_words..self.total) |_| try self.print(" 0x0,", .{});
    try self.print(" }},\n    .x = &.{{", .{});
    for (r.values) |v| for (v.unknowns()[0..words(v.width)]) |x| try self.print(" 0x{x},", .{if (self.two_state) 0 else x});
    for (self.slot_words..self.total) |_| try self.print(" 0x0,", .{});
    try self.print(" }},\n    .slots = {d},\n", .{r.values.len});
    try table(self, "fan_start", p.fan_start);
    try table(self, "fan", p.fan);
    try self.print("    .code_len = {d},\n    .repeats = {d},\n    .joins = {d},\n    .subs = {d},\n", .{ r.code.items.len, r.repeats.items.len, r.joins.items.len, r.subs.items.len });
    if (activations) try actEvents(self);
    if (dumps(r)) try self.print("    .vcd = &vcd_catalog,\n", .{});
    try netTables(self);
    try portTables(self);
    try table(self, "order", order.items);
    if (self.part_start.len != 0) try table(self, "part_start", self.part_start);
    if (schedule == .static) {
        try table(self, "comb_start", p.comb_start);
        try self.print("    .comb = &.{{", .{});
        for (p.comb) |c| try self.print(" .{{ .node = {d}, .word = {d}, .mask = 0x{x} }},", .{ c.node, c.word, c.mask });
        try self.print(" }},\n", .{});
        try self.print("    .nodes = {d},\n", .{p.node_pc.len});
        try table(self, "watch_start", p.watch_start);
        try self.print("    .watchers = &.{{", .{});
        for (p.watchers) |w| try self.print(" .{{ .proc = {d}, .pc = {d}, .edge = .{t} }},", .{ w.proc, w.pc, w.edge });
        try self.print(" }},\n    .triggered = {d},\n", .{p.triggered});
    }
    if (two_phase) {
        try self.print("    .dead = &.{{", .{});
        for (try plan.stepLocal(self, procs.items)) |at| try self.print(" .{{ {d}, {d} }},", .{ self.off[at], words(r.values[at].width) });
        try self.print(" }},\n", .{});
    }
    try self.print("}};\n\n", .{});
    if (dumps(r)) try catalog(self);
    if (self.device) try deviceRoot(self) else if (two_phase) try self.print(
        \\pub fn main(init: std.process.Init) u8 {{
        \\    return rt.auto(init, &design, {d}, Code(false).dispatch, Code(true).dispatch);
        \\}}
        \\
    , .{r.finest}) else try self.print(
        \\pub fn main(init: std.process.Init) u8 {{
        \\    return rt.main(init, &design, {d}, Code(false).dispatch);
        \\}}
        \\
    , .{r.finest});
    return self.out.written();
}

/// `rt.Design.act_events`: per slot, 1 + the automatic timed task whose
/// out-of-line body declares that named event, in its own scope or a
/// block nested there (§10.2.1, `waiters.eventContext`), else 0.
fn actEvents(self: *Emitter) Error!void {
    const r = self.r;
    const owner = try self.arena.alloc(u32, r.values.len);
    @memset(owner, 0);
    var it = r.events.iterator();
    while (it.next()) |ev| for (self.timed.items) |idx| {
        const sub = r.subs.items[idx];
        if (!sub.decl.automatic) continue;
        var scope = ev.value_ptr.scope;
        while (scope != sub.body.?.frame.scope) {
            const info = r.scope_info.items[scope];
            if (!info.lexical) break;
            scope = info.parent;
        } else owner[ev.key_ptr.*] = idx + 1;
    };
    try table(self, "act_events", owner);
}

/// Can simulation time pass 0: does a procedural, intra-assignment, net
/// or gate delay exist?
fn advances(r: *const Run) bool {
    for (r.code.items) |ins| if (ins == .delay or ins == .sample) return true;
    for (r.drivers) |d| if (d.delay.present) return true;
    for (r.net_cold.items) |c| if (c.delay.present) return true;
    return false;
}

/// Node `n`, whose evaluation starts at `pc` in `fn proc<entry>`, in the
/// settle event. A `pureNode` runs whenever a node of its word is dirty:
/// with no operand changed it computes the value its net already holds, and
/// storing that changes nothing (§6.1), so its own dirty bit need not be
/// tested. Any other node runs when its bit says an input changed.
fn settleNode(self: *Emitter, p: plan.Plan, pc: u32, n: u32, entry: u32) Error!void {
    const r = self.r;
    if (!self.pure_nodes[n]) return self.print("    if (s.take({d})) try proc{d}(s.s, {d});\n", .{ n, entry, pc });
    const slot = r.nets[r.drivers[r.code.items[pc].continuous].net].slot;
    if (!self.watched[slot]) return self.print("    try M.set(s, {d}, val{d}(s), {f});\n", .{ self.off[slot], n, full(self.slotWidth(slot)) });
    var wakes = self.reach[slot];
    wakes.comb = false;
    try self.print("    try M.putNode(s, {f}, {d}, {d}, val{d}(s), &.{{", .{ fmtReach(wakes), slot, self.off[slot], n });
    // A pure reader in this node's own dirty word runs after it anyway.
    for (p.comb[p.comb_start[slot]..p.comb_start[slot + 1]]) |e| if (e.node / 64 != n / 64 or !self.pure_nodes[e.node])
        try self.print(" .{{ .node = {d}, .word = {d}, .mask = 0x{x} }},", .{ e.node, e.word - self.off[slot], e.mask });
    try self.print(" }});\n", .{});
}

/// Does the node at `pc` continuously assign a value that reads only nets
/// and variables, of a net that is not a real?
fn pureNode(self: *Emitter, pc: u32) bool {
    const r = self.r;
    const i = switch (r.code.items[pc]) {
        .continuous => |i| i,
        else => return false, // else: an `always @*` node, whose body may do anything
    };
    const d = r.drivers[i];
    return switch (d.source) {
        .expr => |x| pure(self, x.e) and !r.reals.contains(r.nets[d.net].slot),
        .gate => true,
        .bridge, .udp, .mos, .pull => false,
    };
}

/// `fn val<n>`: the value of `pureNode` `n` (at `pc`), read through an
/// `rt.View`, which its process and the settle event both store.
fn nodeValue(self: *Emitter, pc: u32, n: u32) Error!void {
    const r = self.r;
    const d = r.drivers[r.code.items[pc].continuous];
    const slot = r.nets[d.net].slot;
    r.scope = d.scope;
    r.pc = pc;
    const head = self.out.written().len;
    try self.print("fn val{d}(s: rt.View) L.T({d}) {{\n    @setEvalBranchQuota(1 << 30);\n", .{ n, self.slotWidth(slot) });
    const body = self.out.written().len;
    if (d.source == .gate) try planes(self, d.source.gate.ins, d.source.gate.lane);
    try self.print("    return ", .{});
    switch (d.source) {
        .expr => |x| try driverValue(self, x.e, x.slice, slot),
        .gate => |g| try gateLogic(self, g.kind, g.ins.len),
        .bridge, .udp, .mos, .pull => unreachable, // `pureNode` admits these two
    }
    try self.print(";\n}}\n\n", .{});
    if (!usesS(self.out.written()[head..])) try insert(self, body, "    _ = s;\n");
}

/// Does `e` read only nets and variables: no system or user function,
/// whose value or effect a re-evaluation could change?
fn pure(self: *Emitter, e: Ast.ExprId) bool {
    const ex = &self.r.file.exprs;
    switch (ex.tag(e)) {
        .sys_call, .call => return false,
        else => {}, // else: every other form is pure when its operands are
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and !pure(self, c)) return false;
    return true;
}

/// Does the design call a §18 dump task?
pub fn dumps(r: *const Run) bool {
    for (r.code.items) |ins| if (ins == .task and ins.task.task == .dump) return true;
    return false;
}

/// `vcd_catalog`: `vcd.catalog` of the design, with each slot's plane word.
fn catalog(self: *Emitter) Error!void {
    const c = vcd.catalog(self.r, self.arena, self.off) catch return self.refuse("a §18 dump catalog the engine cannot build");
    try self.print("const vcd_catalog: rt.vcd.Catalog = .{{\n    .scopes = &.{{", .{});
    for (c.scopes) |sc| try self.print("\n        .{{ .line = \"{f}\", .parent = {d}, .lexical = {}, .child = {} }},", .{ std.zig.fmtString(sc.line), sc.parent, sc.lexical, sc.child });
    try self.print("\n    }},\n", .{});
    try table(self, "var_start", c.var_start);
    try self.print("    .vars = &.{{", .{});
    for (c.vars) |v| try self.print("\n        .{{ .slot = {d}, .off = {d}, .width = {d}, .real = {}, .event = {}, .head = \"{f}\", .tail = \"{f}\" }},", .{ v.slot, v.off, v.width, v.real, v.event, std.zig.fmtString(v.head), std.zig.fmtString(v.tail) });
    try self.print("\n    }},\n    .finest = {d},\n}};\n\n", .{c.finest});
}

/// `fn show`: the line of `$strobe` or `$monitor` site k, printed when its
/// `.monitor`-region event comes up, in the scope that wrote it (§17.1.2,
/// §17.1.3).
fn emitShows(self: *Emitter) Error!void {
    const r = self.r;
    if (self.shows.items.len == 0) return self.print("fn show(_: *S, _: u32) rt.Error!void {{\n    unreachable;\n}}\n\n", .{});
    try self.print("fn show(s: *S, k: u32) rt.Error!void {{\n    @setEvalBranchQuota(1 << 30);\n    switch (k) {{\n", .{});
    for (self.shows.items, 0..) |pc, k| {
        r.scope = r.code_scope.items[pc];
        r.pc = pc;
        const t = r.code.items[pc].task;
        try self.print("        {d} => {{\n", .{k});
        try show(self, t.args, switch (t.task) {
            .strobe, .monitor => |sh| sh,
            else => unreachable, // else: `site` registers only these two
        }, false);
        try self.print("        }},\n", .{});
    }
    try self.print("        else => unreachable,\n    }}\n}}\n\n", .{});
}

/// The `show` index of the `$strobe`/`$monitor` at `pc`.
fn site(self: *Emitter, pc: u32) Error!u32 {
    const k = std.mem.findScalar(u32, self.shows.items, pc) orelse blk: {
        try self.shows.append(self.arena, pc);
        break :blk self.shows.items.len - 1;
    };
    return @intCast(k);
}

/// The first word of intra-assignment cell `cell`, a `w`-bit value.
fn cellOf(self: *Emitter, cell: u32, w: u32) Error!u32 {
    const g = try self.cells.getOrPut(self.arena, cell);
    if (!g.found_existing) {
        g.value_ptr.* = self.total;
        self.total += words(w);
    }
    return g.value_ptr.*;
}

fn blockEnd(self: *Emitter, start: u32, end: u32) Error!void {
    const g = try self.block_ends.getOrPut(self.arena, start);
    if (!g.found_existing) g.value_ptr.* = .empty;
    try g.value_ptr.append(self.arena, end);
}

fn table(self: *Emitter, name: []const u8, items: []const u32) Error!void {
    try self.print("    .{s} = &.{{", .{name});
    for (items) |v| try self.print(" {d},", .{v});
    try self.print(" }},\n", .{});
}

/// Every pc the process entered at `entry` can reach, ascending, marked in
/// `seen`. The walk is the interpreter's control flow: a suspension resumes
/// at the pc it names, a `.continuous` at itself.
fn reach(self: *Emitter, entry: u32, seen: []bool) Error![]const u32 {
    const r = self.r;
    var pcs: std.ArrayList(u32) = .empty;
    var work: std.ArrayList(u32) = .empty;
    try work.append(self.arena, entry);
    while (work.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        try pcs.append(self.arena, pc);
        if (self.block_ends.get(pc)) |ends| try work.appendSlice(self.arena, ends.items);
        const next = pc + 1;
        switch (r.code.items[pc]) {
            .stop, .continuous => {},
            .jump => |t| try work.append(self.arena, t),
            .restart => |x| try work.append(self.arena, x.target),
            .branch => |b| try work.appendSlice(self.arena, &.{ next, b.otherwise }),
            .case_select => |c| {
                try work.append(self.arena, c.fallback);
                const arms = r.file.stmt(c.statement).case_stmt.arms.len;
                try work.appendSlice(self.arena, r.case_targets.items[c.targets..][0..arms]);
            },
            .repeat_start => |x| try work.appendSlice(self.arena, &.{ next, x.end }),
            .repeat_next => |x| try work.appendSlice(self.arena, &.{ next, x.body }),
            .task => |t| if (t.task != .finish) try work.append(self.arena, next),
            .assign, .init_var, .delay, .wait_event, .wait_slots, .wait_level, .trigger, .sample, .deposit, .call, .copy_out => try work.append(self.arena, next),
            // A disable inside the block it names continues after it.
            .disable_block => |b| try work.appendSlice(self.arena, if (pc >= b.start and pc < b.end) &.{ next, b.end } else &.{next}),
            .disable_task => |idx| {
                try work.append(self.arena, next);
                for (r.subs.items[idx].ranges.items) |rg| if (pc >= rg.start and pc < rg.end) try work.append(self.arena, rg.end);
            },
            // §10.2.3 the body is a process of its own (`timed`); its
            // `.task_return` jumps back to the call site, which then
            // continues past it.
            .call_timed => |c| {
                if (self.device) return self.refuse("a §10.2.3 timed task that reaches itself");
                if (std.mem.findScalar(u32, self.timed.items, c.sub) == null) try self.timed.append(self.arena, c.sub);
                try work.append(self.arena, next);
            },
            .task_return => {},
            .pla_start => |loop| try work.appendSlice(self.arena, &.{ next, loop }),
            .fork => |f| try work.appendSlice(self.arena, if (f.arms.len == 0) &.{f.end} else f.arms),
            .join_arm => |j| try work.append(self.arena, j.end),
            // §9.3 the held slot's own process, started by its `.override_on`.
            .override_on => |o| try work.appendSlice(self.arena, &.{ next, o.start }),
            .override_eval, .override_off => try work.append(self.arena, next),
            .switch_ctrl => {},
        }
    }
    std.mem.sort(u32, pcs.items, {}, std.sort.asc(u32));
    return pcs.items;
}

/// `fn proc<entry>`: the process whose reachable pcs are `pcs`.
fn process(self: *Emitter, pcs: []const u32) Error!void {
    const r = self.r;
    const head = self.out.written().len;
    // Every kernel call folds its widths at compile time, which Zig counts
    // against one quota per function.
    try self.print("fn proc{d}(s: *S, pc: u32) rt.Error!void {{\n    @setEvalBranchQuota(1 << 30);\n", .{pcs[0]});
    for (pcs) |pc| if (r.code.items[pc] == .restart) {
        try self.print("    var restarted = false;\n", .{});
        break;
    };
    const sw = self.out.written().len;
    try self.print("    switch (pc) {{\n", .{});
    for (pcs) |pc| {
        r.scope = r.code_scope.items[pc];
        r.pc = pc;
        try self.print("        {d} => {{\n", .{pc});
        if (self.in_sub) try self.print("            if (s.unwind != null) return;\n", .{});
        try instruction(self, pc);
        try self.print("        }},\n", .{});
    }
    try self.print("        else => unreachable,\n    }}\n}}\n\n", .{});
    // Zig refuses an unused label and an unused parameter, so each is
    // declared only when the body uses it.
    const text = self.out.written()[head..];
    if (std.mem.find(u8, text, "continue :sw") != null) try insert(self, sw + 4, "sw: ");
    if (!usesS(self.out.written()[head..])) try insert(self, sw, "    _ = s;\n");
}

/// Does a function's text use its parameter `s`?
fn usesS(text: []const u8) bool {
    return std.mem.find(u8, text, "s.") != null or std.mem.find(u8, text, "(s,") != null;
}

fn insert(self: *Emitter, at: usize, text: []const u8) Error!void {
    var list = self.out.toArrayList();
    list.insertSlice(self.arena, at, text) catch return error.OutOfMemory;
    self.out = .fromArrayList(self.arena, &list);
}

/// One arm's body: the instruction at `pc`, `exec.execute`'s arm for arm.
fn instruction(self: *Emitter, pc: u32) Error!void {
    const r = self.r;
    const next = pc + 1;
    switch (r.code.items[pc]) {
        .stop => try self.print("            return;\n", .{}),
        .init_var => |x| {
            try self.print("            ", .{});
            try self.store(x.slot, .blocking);
            try expr.assigned(self, x.value, self.r.slotType(x.slot));
            try self.print(", {f});\n            continue :sw {d};\n", .{ full(self.slotWidth(x.slot)), next });
        },
        .assign => |x| {
            try assignment(self, x.target, .{ .expr = x.value }, if (x.nonblocking) .nba else .blocking);
            try self.print("            continue :sw {d};\n", .{next});
        },
        .delay => |x| {
            try self.print("            try s.run({d}, ", .{next});
            try delay(self, x.amount);
            try self.print(");\n            return;\n", .{});
        },
        .task => |t| {
            switch (t.task) {
                .show => |sh| try show(self, t.args, sh, false),
                .finish => |stop| {
                    try self.print("            return s.{s}(", .{if (stop) "stopRun" else "finish"});
                    if (t.args.len == 0) try self.print("true", .{}) else {
                        try self.print("(L.asInt(", .{});
                        const ty = try expr.selfDetermined(self, t.args[0]);
                        try self.print(", {d}, {}) orelse 1) != 0", .{ ty.width, ty.signed });
                    }
                    const start = r.starts[t.tok];
                    const loc = r.bag.locate(.{ .start = start, .end = start }, null);
                    try self.print(", \"{f}\", {d});\n", .{ std.zig.fmtString(r.bag.fileName(loc.file)), loc.offset });
                    return;
                },
                // §17.3.2: the three numbers are read when the task runs, an
                // x/z one as 0.
                .timeformat => if (t.args.len == 0) {
                    try self.print("            s.time_format = .{{ .units = {d} }};\n", .{r.finest});
                } else {
                    try self.print("            s.time_format = .{{ .units = std.math.lossyCast(i32, ", .{});
                    try int(self, t.args[0]);
                    try self.print("), .precision = std.math.lossyCast(u32, ", .{});
                    try int(self, t.args[1]);
                    try self.print("), .suffix = \"{f}\", .width = std.math.lossyCast(u32, ", .{std.zig.fmtString(r.file.str(r.file.exprs.strOf(t.args[2])))});
                    try int(self, t.args[3]);
                    try self.print(") }};\n", .{});
                },
                .printtimescale => try self.print("            try s.out.writeAll(\"{f}\");\n", .{std.zig.fmtString(try staticText(self, display.printTimescale, .{t.args}))}),
                // §17.1.2: the call is queued, its arguments are read then.
                .strobe => |sh| {
                    if (sh.file) return self.refuse("§17.2.2 $fstrobe: a strobe written to a file descriptor");
                    try self.print("            try s.strobe({d});\n", .{try site(self, pc)});
                },
                // §17.1.3: one standing monitor, which a change of any
                // slot its arguments read asks to print.
                .monitor => |sh| {
                    if (sh.file) return self.refuse("§17.2.2 $fmonitor: a monitor written to a file descriptor");
                    for (t.args) |arg| if (display.comparedOperand(r, arg))
                        return self.refuse("§17.1.3 a $monitor argument that is an expression (a select, an operator), which reports only when its value changes");
                    var slots: std.ArrayList(u32) = .empty;
                    for (t.args) |arg| if (arg != .none and r.file.exprs.tag(arg) != .str_literal)
                        compile.sensitivity(r, arg, &slots) catch return self.refuse("a monitor argument the engine resolves only at run time");
                    try self.print("            try s.monitor({d}, &.{{", .{try site(self, pc)});
                    for (slots.items) |at| try self.print(" {d},", .{at});
                    try self.print(" }});\n", .{});
                },
                // "$monitoron shall produce a display immediately".
                .monitor_enable => |on| if (on)
                    try self.print("            if (s.monitorEnable(true)) |k| try show(s, k);\n", .{})
                else
                    try self.print("            _ = s.monitorEnable(false);\n", .{}),
                // §17.2.9: the bounds are read now; the file when the task runs.
                .readmem => |radix| {
                    if (self.device) return self.refuse("§17.2.9 $readmemb/$readmemh: a device reads no file");
                    const base = try self.slot(t.args[1]);
                    const arr = r.arrays.get(base).?;
                    const name = r.file.str(r.file.exprs.strOf(t.args[0]));
                    try self.print("            try s.readmem(\"{f}\", \"{f}\", .{t}, ", .{ std.zig.fmtString(r.file_name), std.zig.fmtString(name), radix });
                    try self.print("{d}, {d}, {d}, {d}, {d}, {d}", .{ self.slotWidth(base), base, self.off[base], arr.low, arr.high, t.args.len - 2 });
                    for (2..4) |k| {
                        try self.print(", ", .{});
                        if (k < t.args.len) try int64(self, t.args[k]) else try self.print("null", .{});
                    }
                    try self.print(");\n", .{});
                },
                // §17.6: inputs read, the shared queue engine, then each
                // output written as `evaluate.assignInt` writes it, status last.
                .queue => |op| {
                    if (self.device) return self.refuse("a §17.6 stochastic queue, whose length a device's state cannot bound");
                    const lb = self.label();
                    const scale = r.timeOf(r.scope).scale;
                    try self.print("            const q{d} = try s.queue(.{t}, ", .{ lb, op });
                    try int64(self, t.args[0]);
                    try self.print(", ", .{});
                    if (op == .initialize or op == .add or op == .exam) try int64(self, t.args[1]) else try self.print("null", .{});
                    try self.print(", ", .{});
                    if (op == .initialize or op == .add) try int64(self, t.args[2]) else try self.print("null", .{});
                    try self.print(", .{{ .local_per_unit = {d}, .global_per_local = {d} }});\n", .{ scale.local_per_unit, scale.global_per_local });
                    for (1..3) |k| if (op == .remove or (op == .exam and k == 2)) {
                        try self.print("            if (q{d}.out[{d}]) |v{d}| {{\n", .{ lb, k - 1, lb });
                        try assignInt(self, t.args[k], try self.arena.print("v{d}", .{lb}));
                        try self.print("            }}\n", .{});
                    };
                    try assignInt(self, t.args[3], try self.arena.print("q{d}.status", .{lb}));
                },
                // §17.5: the outputs through a cell as wide as they are.
                .pla => |p| {
                    const base = try self.slot(t.args[0]);
                    const ty = try targetType(self, t.args[2]);
                    if (ty.real) return self.refuse("a §17.5 PLA writing a real");
                    if (p.plane) try self.xMeaning("a §17.5.4 plane PLA, whose z personality bits mean \"ignore this input\"", t.tok);
                    self.keepFour("a §17.5 PLA, whose outputs are x where no row decides", t.tok);
                    const at = try cellOf(self, std.math.maxInt(u32) - words(ty.width), ty.width);
                    try self.print("            try s.pla(.{{ .logic = .@\"{t}\", .plane = {}, .async_ = false }}, {d}, {d}, {d}, ", .{
                        p.logic, p.plane, self.off[base], r.arrays.get(base).?.count, self.slotWidth(base),
                    });
                    const in = try expr.selfDetermined(self, t.args[1]);
                    try self.print(", {d}, {d}, {d});\n", .{ in.width, at, ty.width });
                    try assignment(self, t.args[2], .{ .stored = .{ .off = at, .ty = .{ .width = ty.width, .signed = false } } }, .blocking);
                },
                .fflush => {},
                .user => return self.refuse("a PLI application's system task, which runs only under a VPI host"),
                .ports => |op| try portTask(self, pc, op, t.args),
                .fclose => {
                    try self.print("            s.fclose(", .{});
                    try int64(self, t.args[0]);
                    try self.print(");\n", .{});
                },
                // §17.2.2: the descriptor is read first; an x or z one
                // prints nothing.
                .fshow => |sh| {
                    const lb = self.label();
                    try self.print("            if (", .{});
                    try int64(self, t.args[0]);
                    try self.print(") |d{d}| {{\n            s.capture();\n", .{lb});
                    try show(self, t.args[1..], sh, false);
                    try self.print("            try s.fshow(d{d});\n            }}\n", .{lb});
                },
                .sshow => |sh| {
                    try self.print("            s.capture();\n", .{});
                    try show(self, t.args[1..], sh, false);
                    try assignChars(self, t.args[0], "s.captured()");
                },
                .sformat => {
                    try self.print("            s.capture();\n", .{});
                    if (r.file.exprs.tag(t.args[1]) == .str_literal)
                        try show(self, t.args[1..], .{ .radix = .decimal, .newline = false }, true)
                    else
                        try dynamicFormat(self, t.args[1..]);
                    try assignChars(self, t.args[0], "s.captured()");
                },
                // §18.1: the arguments are read now; the targets were
                // resolved at elaboration.
                .dump => |op| switch (op) {
                    .file => if (t.args.len == 1) {
                        try self.print("            try s.dumpFile(", .{});
                        const n = try expr.selfDetermined(self, t.args[0]);
                        try self.print(", {d}, \"{f}\");\n", .{ n.width, std.zig.fmtString(vcd.callText(r.text, r.starts[t.tok])) });
                    },
                    .vars => {
                        try self.print("            try s.dumpVars(", .{});
                        if (t.args.len == 0) {
                            try self.print("0, &.{{", .{});
                            for (r.roots) |sc| try self.print(" .{{ .scope = {d} }},", .{sc});
                            try self.print(" }});\n", .{});
                        } else {
                            try int64(self, t.args[0]);
                            try self.print(", &.{{", .{});
                            for (t.args[1..]) |e| switch (vcd.target(r, e) catch return self.refuse("a $dumpvars target the engine resolves only at run time")) {
                                .scope => |sc| try self.print(" .{{ .scope = {d} }},", .{sc}),
                                .slot => |sl| try self.print(" .{{ .slot = {d} }},", .{sl}),
                            };
                            try self.print(" }});\n", .{});
                        }
                    },
                    .limit => {
                        try self.print("            s.dump.limit = std.math.lossyCast(u64, ", .{});
                        try int(self, t.args[0]);
                        try self.print(");\n", .{});
                    },
                    .off, .on, .all, .flush => try self.print("            try s.dumpControl(.{t});\n", .{op}),
                },
            }
            try self.print("            continue :sw {d};\n", .{next});
        },
        // A backward jump is one pass of a loop: `exec.loopIteration`.
        .jump => |t| try self.print("{s}            continue :sw {d};\n", .{ if (t <= pc) "            try s.loopIteration();\n" else "", t }),
        .branch => |b| {
            // Two constant `continue`s: each is a direct jump, where one
            // `continue` of a selected pc is a jump through the table.
            try self.print("            if (", .{});
            try expr.truth(self, b.condition);
            try self.print(" == .one) continue :sw {d};\n            continue :sw {d};\n", .{ next, b.otherwise });
        },
        .case_select => |c| {
            const case = r.file.stmt(c.statement).case_stmt;
            try self.fits(c.ty);
            try self.print("            const v = ", .{});
            try expr.value(self, case.scrutinee, c.ty);
            try self.print(";\n", .{});
            // A case of only `default` reads its scrutinee and nothing else.
            for (case.arms) |arm| {
                if (arm.labels.len != 0) break;
            } else try self.print("            _ = v;\n", .{});
            for (case.arms, 0..) |arm, i| for (arm.labels) |lb| {
                try self.print("            if (L.caseMatch(.{t}, v, ", .{case.kind});
                try expr.caseLabel(self, lb, c.ty, case.kind);
                try self.print(")) continue :sw {d};\n", .{r.case_targets.items[c.targets + i]});
            };
            try self.print("            continue :sw {d};\n", .{c.fallback});
        },
        .repeat_start => |x| {
            try self.print("            const n = rt.repeatCount(", .{});
            const ty = try expr.selfDetermined(self, x.count);
            try self.print(", {d}, {});\n            s.repeats[{d}] = n;\n            if (n == 0) continue :sw {d};\n            continue :sw {d};\n", .{ ty.width, ty.signed, x.counter, x.end, next });
        },
        .repeat_next => |x| try self.print("            s.repeats[{d}] -= 1;\n            if (s.repeats[{d}] != 0) {{\n                try s.loopIteration();\n                continue :sw {d};\n            }}\n            continue :sw {d};\n", .{ x.counter, x.counter, x.body, next }),
        .wait_event => |e| {
            if (try waitFixed(self)) return;
            try self.print("            const id = try s.park({d});\n", .{next});
            var ts: std.ArrayList(plan.Term) = .empty;
            try plan.terms(self, e, &ts);
            try eventWatches(self, ts.items);
            try self.print("            return;\n", .{});
        },
        .wait_slots => |slots| {
            if (try waitFixed(self)) return;
            // An `assign` or `force` of a constant waits on nothing.
            if (slots.len == 0) return self.print("            _ = try s.park({d});\n            return;\n", .{next});
            try self.print("            const id = try s.park({d});\n", .{next});
            for (slots) |at| try self.print("            try s.watch(id, {d}, .any);\n", .{at});
            try self.print("            return;\n", .{});
        },
        .wait_level => |x| {
            // Its slots were never planned as watched.
            if (self.in_sub) return self.refuse("a `wait` in a task with no other timing control");
            try self.print("            if (", .{});
            try expr.truth(self, x.cond);
            // An empty list suspends with nothing to wake it (IEEE 1364-2005 §9.7.6).
            if (x.slots.len == 0) return self.print(" == .one) continue :sw {d};\n            _ = try s.park({d});\n            return;\n", .{ next, pc });
            try self.print(" == .one) continue :sw {d};\n            const id = try s.park({d});\n", .{ next, pc });
            for (x.slots) |at| try self.print("            try s.watch(id, {d}, .any);\n", .{at});
            try self.print("            return;\n", .{});
        },
        .trigger => |event| switch (event) {
            .slot => |at| try self.print("            {s}try s.wake({d}, .x, .x);\n            continue :sw {d};\n", .{ if (dumps(r)) try self.arena.print("s.fire({d});\n            ", .{at}) else "", at, next }),
            .indexed => |e| {
                try self.print("            if (", .{});
                try expr.address(self, e, self.label());
                try self.print(") |at| {{\n", .{});
                if (dumps(r)) try self.print("                s.fire(at);\n", .{});
                try self.print("                try s.wake(at, .x, .x);\n            }}\n            continue :sw {d};\n", .{next});
            },
        },
        .restart => |x| try self.print(
            \\            if (restarted) return s.fail("this always process completed an iteration without suspending; it needs a delay or event control", .{{}});
            \\            restarted = true;
            \\            continue :sw {d};
            \\
        , .{x.target}),
        .continuous => |i| try continuous(self, pc, i),
        // §9.7.7 the value is read now; a nonblocking update is scheduled at
        // once, a blocking one parked in its cell until the control passes.
        .sample => |x| {
            const st = r.file.stmt(x.statement).assign;
            if (st.nonblocking and st.timing_is_delay) {
                try assignment(self, st.target, .{ .expr = st.value }, .{ .nba_after = st.timing });
                return self.print("            continue :sw {d};\n", .{next});
            }
            const ty = try targetType(self, st.target);
            try self.print("            try M.set(s, {d}, ", .{try cellOf(self, x.cell, ty.width)});
            try expr.assigned(self, st.value, ty);
            try self.print(", {f});\n", .{full(ty.width)});
            if (compile.parksOnly(st)) return self.print("            continue :sw {d};\n", .{next});
            if (st.timing_is_delay) {
                try self.print("            try s.run({d}, ", .{next});
                try delay(self, st.timing);
                return self.print(");\n            return;\n", .{});
            }
            try self.print("            const id = try s.park({d});\n", .{next});
            var ts: std.ArrayList(plan.Term) = .empty;
            try plan.terms(self, st.timing, &ts);
            try eventWatches(self, ts.items);
            try self.print("            return;\n", .{});
        },
        // The target is resolved when the process resumes (§9.7.7).
        .deposit => |x| {
            const st = r.file.stmt(x.statement).assign;
            const ty = try targetType(self, st.target);
            try assignment(self, st.target, .{ .stored = .{ .off = try cellOf(self, x.cell, ty.width), .ty = .{ .width = ty.width, .signed = false } } }, if (st.nonblocking) .nba else .blocking);
            try self.print("            continue :sw {d};\n", .{next});
        },
        // §10.3: a disable inside the block it names continues after it.
        .disable_block => |b| {
            if (pc >= b.start and pc < b.end and hostsOthers(r, b.start, b.end)) return self.refuse(disable_inside);
            try self.print("            try s.disable({d}, {d}, {d});\n            continue :sw {d};\n", .{
                b.start, b.end, b.end, if (pc >= b.start and pc < b.end) b.end else next,
            });
        },
        // §10.3 every activation of the task ends: each inlined copy, and
        // the synchronous ones, which unwind back to their callers.
        .disable_task => |idx| {
            var after = next;
            for (r.subs.items[idx].ranges.items) |rg| {
                if (pc >= rg.start and pc < rg.end and hostsOthers(r, rg.start, rg.end)) return self.refuse(disable_inside);
                try self.print("            try s.disable({d}, {d}, {d});\n", .{ rg.start, rg.end, rg.end });
                if (pc >= rg.start and pc < rg.end) after = rg.end;
            }
            try self.print("            if (s.active[{d}] != 0) {{\n                s.unwind = {d};\n                return;\n            }}\n            continue :sw {d};\n", .{ idx, idx, after });
        },
        .call => |c| {
            try call(self, c.sub, c.args, self.label());
            try self.print("            continue :sw {d};\n", .{next});
        },
        // §10.2.2 an inlined task's output, copied back in the caller's scope.
        .copy_out => |c| {
            try assignment(self, c.target, .{ .stored = .{ .off = self.off[c.slot], .ty = self.r.slotType(c.slot) } }, .blocking);
            try self.print("            continue :sw {d};\n", .{next});
        },
        // §9.8.2: every arm starts now; the last one back resumes the parent.
        .fork => |f| {
            if (f.arms.len == 0) return self.print("            continue :sw {d};\n", .{f.end});
            try self.print("            s.joins[{d}] = {d};\n", .{ f.join, f.arms.len });
            for (f.arms) |arm| try self.print("            try s.run({d}, null);\n", .{arm});
            try self.print("            return;\n", .{});
        },
        .join_arm => |j| try self.print("            s.joins[{d}] -= 1;\n            if (s.joins[{d}] == 0) try s.run({d}, null);\n            return;\n", .{ j.join, j.join, j.end }),
        // §17.5 an asynchronous array's own process starts now.
        .pla_start => |loop| try self.print("            try s.run({d}, null);\n            continue :sw {d};\n", .{ loop, next }),
        .override_on => |o| if (o.bits) |b|
            try self.print("            try s.overrideBits({d}, {d}, {d}, {d}, {d}, {d});\n            continue :sw {d};\n", .{ o.slot, partOf(self, o.slot, b).?, b.lo, b.width, o.start, o.end, next })
        else
            try self.print("            try s.overrideOn({d}, {}, {d}, {d});\n            continue :sw {d};\n", .{ o.slot, o.force, o.start, o.end, next }),
        // An `assign` under a `force` keeps tracking but does not write.
        .override_eval => |o| {
            try self.print("            if ({} or !s.forced({d})) {{\n            s.overriding = true;\n            defer s.overriding = false;\n            ", .{ o.force, o.slot });
            if (o.bits) |b| {
                try self.print("try s.putBits({d}, {d}, {d}, {d}, {d}, ", .{ o.slot, self.off[o.slot], b.lo, b.width, self.slotWidth(o.slot) });
                try expr.assigned(self, o.value, .{ .width = b.width, .signed = false });
                return self.print(");\n            }}\n            continue :sw {d};\n", .{next});
            }
            try self.store(o.slot, .blocking);
            // An operand of a §9.3 concatenation target takes its window of
            // the value, evaluated as wide as the whole target.
            if (o.slice) |sl| {
                try self.print("L.part(", .{});
                try expr.assigned(self, o.value, .{ .width = sl.of, .signed = false });
                try self.print(", {d}, {d}, {d})", .{ sl.lo, self.slotWidth(o.slot), sl.of });
            } else try expr.assigned(self, o.value, self.r.slotType(o.slot));
            try self.print(", {f});\n            }}\n            continue :sw {d};\n", .{ full(self.slotWidth(o.slot)), next });
        },
        // §9.3.2: a released net is its driver's again, at once.
        .override_off => |o| {
            if (o.bits) |b| {
                // Releasing a select never forced is a no-op (`waiters.releaseBits`).
                if (partOf(self, o.slot, b)) |k| {
                    const net = r.net_of.get(o.slot) orelse return self.refuse("a force of a select of a variable");
                    try self.print("            try s.releaseBits({d}, {d});\n            try s.resolve({d});\n", .{ o.slot, k, self.net_ix[net].? });
                }
                return self.print("            continue :sw {d};\n", .{next});
            }
            if (r.net_of.get(o.slot)) |net| {
                if (self.net_ix[net]) |k| {
                    try self.print("            if (try s.release({d}, true)) try s.resolve({d});\n            continue :sw {d};\n", .{ o.slot, k, next });
                    return;
                }
                const drivers = r.netDrivers(net);
                if (drivers.len != 1) return self.refuse("releasing a net without exactly one driver");
                const at = for (r.code.items, 0..) |ins, i| {
                    if (ins == .continuous and ins.continuous == drivers[0]) break i;
                } else return self.refuse("releasing a net whose driver is not a process");
                try self.print("            if (try s.release({d}, true)) try proc{d}(s, {d});\n", .{ o.slot, at, at });
            } else try self.print("            _ = try s.release({d}, {});\n", .{ o.slot, o.force });
            try self.print("            continue :sw {d};\n", .{next});
        },
        // §7.6 a controlled pass switch: read the control, re-resolve both
        // sides (`rt.net.switchCtrl`), and re-arm on the control's operands.
        .switch_ctrl => |sc| {
            try bits(self, &.{r.trans[sc.tran].ctrl}, 0);
            try self.print("            try s.switchCtrl({d}, b[0]);\n            s.armed[{d}] = true;\n            return;\n", .{ sc.tran, pc });
        },
        .call_timed => |c| try callTimed(self, pc, c.sub, c.args),
        // §10.2.2 the outputs are put aside (`retCell`) while this
        // activation's storage is still resident; the call site copies them.
        .task_return => |idx| {
            const sub = r.subs.items[idx];
            for (sub.decl.ports, sub.body.?.frame.ports) |p, at| if (p.direction != .input) {
                try self.print("            try M.set(s, {d}, ", .{try retCell(self, at)});
                try self.get(at);
                try self.print(", {f});\n", .{full(self.slotWidth(at))});
            };
            try self.print("            s.jump = try s.returnTimed();\n            return;\n", .{});
        },
    }
}

const disable_inside = "a §10.3 disable from inside a block other processes may still be inside";

/// Can another process be suspended or queued inside pcs [start, end) when a
/// `disable` inside them runs: a §9.8.2 fork arm, a process a `pla_start`
/// or `override_on` starts, or a §9.7.2 expression term's tracker, whose
/// first instruction keeps its hidden slot (`compile.exprTerm`)? Then
/// `rt.State.disable` would resume the end besides the disabling process,
/// which `exec.disableInside` avoids and `rt` cannot yet.
fn hostsOthers(r: *const Run, start: u32, end: u32) bool {
    // ponytail: a refusal; `rt` exposing `stop` lets these disables be native.
    for (r.code.items[start..end]) |ins| switch (ins) {
        .fork, .pla_start, .override_on => return true,
        .init_var => |x| {
            var it = r.term_slots.valueIterator();
            while (it.next()) |at| if (at.* == x.slot) return true;
        },
        else => {}, // else: every other instruction runs in the process that reaches it
    };
    return false;
}

/// The cell a timed task's output formal `at` waits in between its
/// activation's return and its call site's copy-out.
fn retCell(self: *Emitter, at: u32) Error!u32 {
    return cellOf(self, (1 << 31) + at, self.slotWidth(at));
}

/// `exec.callTimed` and, when `s.returned`, the end of `exec.returnTimed`:
/// the inputs read in the caller, a new activation (`rt.State.callTimed`)
/// with the formals set, and a jump to the body; on return, the outputs
/// copied to the actuals in the caller's restored activation (§10.2.2,
/// §10.2.3).
fn callTimed(self: *Emitter, pc: u32, idx: u32, args: []const Ast.ExprId) Error!void {
    const r = self.r;
    const sub = r.subs.items[idx];
    const f = sub.body.?.frame;
    try self.print("            if (s.returned) {{\n                s.returned = false;\n", .{});
    for (sub.decl.ports, args, f.ports) |p, arg, at| if (p.direction != .input)
        try assignment(self, arg, .{ .stored = .{ .off = try retCell(self, at), .ty = self.r.slotType(at) } }, .blocking);
    try self.print("                continue :sw {d};\n            }}\n", .{pc + 1});
    const lb = self.label();
    for (sub.decl.ports, args, f.ports, 0..) |p, arg, at, i| if (p.direction != .output) {
        try self.print("            const i{d}_{d} = ", .{ lb, i });
        try expr.assigned(self, arg, self.r.slotType(at));
        try self.print(";\n", .{});
    };
    const lo = self.slotOff(f.first);
    try self.print("            try s.callTimed({d}, {d}, {d}, ", .{ idx, pc, lo });
    if (sub.decl.automatic) try self.print("&tfill{d});\n", .{idx}) else try self.print("&.{{}});\n", .{});
    for (sub.decl.ports, f.ports, 0..) |p, at, i| if (p.direction != .output)
        try self.print("            try M.set(s, {d}, i{d}_{d}, {f});\n", .{ self.off[at], lb, i, full(self.slotWidth(at)) });
    try self.print("            s.jump = {d};\n            return;\n", .{sub.body.?.entry});
}

/// File a wait's terms. Ordinary terms keep the direct slot path; an event
/// array carries an emitted selector and the full range of element slots.
fn eventWatches(self: *Emitter, ts: []const plan.Term) Error!void {
    for (ts) |t| {
        if (t.width != 0) {
            try self.print("            try s.watchBits(id, {d}, {d}, {d}, {d}, .{t});\n", .{ t.slot, self.off[t.slot], t.lo, t.width, t.edge });
            continue;
        }
        if (t.event_select == .none) {
            try self.print("            try s.watch(id, {d}, .{t});\n", .{ t.slot, t.edge });
            continue;
        }
        const index = self.event_selects.items.len;
        try self.event_selects.append(self.arena, .{ .e = t.event_select, .scope = self.r.scope });
        try self.print("            try s.watchSelected(id, {d}, {d}, selectedEvent{d});\n", .{ t.slot, t.count, index });
    }
}

/// The selector body lives inside Code so its ordinary expressions use M.
/// The immutable wrapper outside Code chooses the occurrence's logic phase.
fn eventSelectors(self: *Emitter) Error!void {
    const scope = self.r.scope;
    defer self.r.scope = scope;
    for (self.event_selects.items, 0..) |select, i| {
        self.r.scope = select.scope;
        try self.print("fn eventSelect{d}(s: *S) rt.Error!?u32 {{\n    _ = &s;\n    return ", .{i});
        try expr.address(self, select.e, self.label());
        try self.print(";\n}}\n\n", .{});
    }
}

/// IEEE 1364-2005 §14.2.4.1 each conditional module path of the `rt` nets,
/// in `netTables`' order, as `fn pathCond<i>`: "If the conditional
/// expression evaluates to x or z, it shall be treated as true. If [it]
/// evaluates to multiple bits, the least significant bit shall represent the
/// result."
fn pathConds(self: *Emitter) Error!void {
    const r = self.r;
    const scope = r.scope;
    defer r.scope = scope;
    var i: u32 = 0;
    for (self.rt_nets.items) |k| for (r.netCold(r.nets[k]).paths) |p| if (p.cond != .none) {
        r.scope = p.scope;
        try self.print("pub fn pathCond{d}(s: *S) rt.Error!bool {{\n    _ = &s;\n    return L.low(", .{i});
        _ = try expr.selfDetermined(self, p.cond);
        try self.print(") != .zero;\n}}\n\n", .{});
        i += 1;
    };
}

/// The entry of a triggered process or node: it waits by being listed in
/// `rt.Design.watchers` or `comb`, so arriving here only says so (a
/// triggered process records its suspension stamp, `rt.State.stamp`).
fn waitFixed(self: *Emitter) Error!bool {
    switch (self.role) {
        .general => return false,
        .triggered => |t| try self.print("            s.waiting[{d}] = s.stamp();\n            return;\n", .{t}),
        .comb => try self.print("            return;\n", .{}),
    }
    return true;
}

/// `evaluate.targetType`: the type a value assigned to `target` takes.
pub fn targetType(self: *Emitter, target: Ast.ExprId) Error!Type {
    const r = self.r;
    const ex = &r.file.exprs;
    // `evaluate.targetType`: as wide as its operands together, unsigned.
    if (ex.tag(target) == .concat) {
        var width: u32 = 0;
        for (ex.args(target)) |x| width += (try targetType(self, x)).width;
        return .{ .width = width, .signed = false };
    }
    if (ex.tag(target) != .index) return r.slotType(try self.slot(target));
    if (try self.element(target)) return r.slotType(try self.slot(r.chainBase(target).base));
    return .{ .width = compile.typeOf(r, target).width, .signed = false };
}

/// A.6.2 `lvalue = value` or `lvalue <= value`: `evaluate.place`, then
/// `evaluate.evalFor`, then `write` now or an NBA row (§9.2.2).
fn assignment(self: *Emitter, target: Ast.ExprId, val: Rhs, how: How) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    // `evaluate.put`: the value once, then each operand its bits, the rightmost
    // the least significant (§6 Table 6-1).
    if (ex.tag(target) == .concat) {
        const total = (try targetType(self, target)).width;
        const lb = self.label();
        try self.print("            {{\n            const cat{d} = ", .{lb});
        try rhsFor(self, val, .{ .width = total, .signed = false });
        try self.print(";\n", .{});
        var lo = total;
        for (ex.args(target)) |arg| {
            lo -= (try targetType(self, arg)).width;
            try assignment(self, arg, .{ .part = .{ .label = lb, .lo = lo, .total = total } }, how);
        }
        return self.print("            }}\n", .{});
    }
    if (ex.tag(target) == .index and (val == .expr or val == .stored)) {
        // §9.2 evaluates the RHS even when §5.2's index names no storage.
        // Capture once before any address/unknown guard. This also keeps
        // function effects from being duplicated across a packed write. A
        // stored system-function result also needs this copy: an index's
        // nested call can reuse that function's temporary slot.
        const lb = self.label();
        const ty = try targetType(self, target);
        try self.print("            {{\n            const v{d} = ", .{lb});
        try rhsFor(self, val, ty);
        try self.print(";\n", .{});
        try assignment(self, target, .{ .evaluated = .{ .label = lb, .ty = ty } }, how);
        return self.print("            }}\n", .{});
    }
    if (ex.tag(target) != .index) {
        const at = try self.slot(target);
        try self.print("            ", .{});
        try self.store(at, how);
        try rhsFor(self, val, self.r.slotType(at));
        return self.print(", {f});\n", .{full(self.slotWidth(at))});
    }
    if (try self.element(target)) {
        const base = try self.slot(r.chainBase(target).base);
        const lb = self.label();
        try self.print("            if (", .{});
        try expr.address(self, target, lb);
        try self.print(") |a{d}| ", .{lb});
        try self.storeElement(base, lb, how);
        try rhsFor(self, val, self.r.slotType(base));
        return self.print(", {f});\n", .{full(self.slotWidth(base))});
    }
    // §5.2.1 a select of a vector: unsigned, as wide as it selects.
    const vector = ex.lhs(target);
    const at = try self.slot(r.chainBase(vector).base);
    const element_label: ?u32 = if (ex.tag(vector) == .index) self.label() else null;
    if (element_label) |lb| {
        try self.print("            if (", .{});
        try expr.address(self, vector, lb);
        try self.print(") |a{d}| {{\n", .{lb});
    }
    try assignSelect(self, target, at, element_label, val, how);
    if (element_label != null) try self.print("            }}\n", .{});
}

/// The masked write of a packed select, after an optional array address
/// has been captured. Its slot and mask are captured now even for an NBA.
fn assignSelect(self: *Emitter, target: Ast.ExprId, at: u32, element_label: ?u32, val: Rhs, how: How) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const sw = self.slotWidth(at);
    const range = expr.vecRange(r, at, sw);
    const rg = ex.rhs(target);
    if (ex.tag(rg) == .range) {
        const p = try expr.partPlace(self, target, range);
        try self.print("            ", .{});
        try storeSelected(self, at, element_label, how);
        try self.print("L.place(", .{});
        try rhsFor(self, val, .{ .width = p.count, .signed = false });
        return self.print(", {d}, {d}, {d}), L.field({d}, {d}, {d}));\n", .{ p.shift, p.count, sw, p.shift, p.count, sw });
    }
    const lb = self.label();
    if (ex.tag(rg) == .indexed_range) {
        const count = compile.typeOf(r, target).width;
        try self.print("            if (", .{});
        try expr.indexedShift(self, target, range);
        try self.print(") |q{d}| ", .{lb});
        try storeSelected(self, at, element_label, how);
        try self.print("L.place(", .{});
        try rhsFor(self, val, .{ .width = count, .signed = false });
        return self.print(", q{d}, {d}, {d}), L.field(q{d}, {d}, {d}));\n", .{ lb, count, sw, lb, count, sw });
    }
    try self.print("            if (L.pos(L.asIndex(", .{});
    const t = try expr.selfDetermined(self, rg);
    try self.print(", {d}, {}), {d}, {d}, {d})) |q{d}| ", .{ t.width, t.signed, range.msb, range.lsb, sw, lb });
    if (sw > 64 and how == .blocking and element_label == null) {
        // One bit of a wide vector: the store touches only its word.
        if (self.watched[at])
            try self.print("try M.putWord(s, {f}, {d}, {d}, q{d} / 64, ", .{ fmtReach(self.reach[at]), at, self.off[at], lb })
        else
            try self.print("try M.set(s, {d} + q{d} / 64, ", .{ self.off[at], lb });
        try self.print("L.up(", .{});
        try rhsFor(self, val, .{ .width = 1, .signed = false });
        return self.print(", q{d} % 64, 64), L.bit(q{d} % 64, 64));\n", .{ lb, lb });
    }
    try storeSelected(self, at, element_label, how);
    try self.print("L.up(", .{});
    try rhsFor(self, val, .{ .width = 1, .signed = false });
    try self.print(", q{d}, {d}), L.bit(q{d}, {d}));\n", .{ lb, sw, lb, sw });
}

fn storeSelected(self: *Emitter, at: u32, element_label: ?u32, how: How) Error!void {
    if (element_label) |lb| return self.storeElement(at, lb, how);
    return self.store(at, how);
}

/// `exec.delayOf` of an integral delay, in ticks: folded when constant.
fn delay(self: *Emitter, amount: Ast.ExprId) Error!void {
    const r = self.r;
    const scale = r.timeOf(r.scope).scale;
    const t = compile.typeOf(self.r, amount);
    if (t.real) {
        // A constant no tick count holds fails at run time, as the
        // interpreter's does, through `s.realTicks`: a `return` here would
        // sit in the argument list of the call that schedules the delay.
        if (compile.constantExpression(r, amount)) fold: {
            const v = evaluate.evalReal(r, self.arena, amount) catch return self.refuse("a delay the engine does not fold");
            const ticks = scale.realDelay(v) catch break :fold;
            return self.print("{d}", .{ticks});
        }
        try self.print("try s.realTicks(", .{});
        try expr.real(self, amount);
        return self.print(", .{{ .local_per_unit = {d}, .global_per_local = {d} }})", .{ scale.local_per_unit, scale.global_per_local });
    }
    if (t.width > 64) return self.refuse("a delay wider than 64 bits");
    if (compile.constantExpression(r, amount)) fold: {
        const v = evaluate.eval(r, self.arena, amount, 0) catch return self.refuse("a delay the engine does not fold");
        // `--two-state` computes an unknown constant from its 0-valued leaves.
        if (self.two_state and v.hasUnknown()) break :fold;
        const ticks = if (v.hasUnknown()) 0 else (if (v.signed) scale.signedDelay(v.asInt().?) else scale.unsignedDelay(v.values()[0])) catch break :fold;
        return self.print("{d}", .{ticks});
    }
    // `s.ticks` reads the 64-bit word as a time: a narrower signed delay is
    // sign-extended to it first, so a negative one is the §9.7.1 64-bit
    // two's complement `exec.delayOf` takes, not its own width's.
    try self.print("try s.ticks(", .{});
    if (t.signed and t.width < 64) {
        try self.print("L.rs(", .{});
        try expr.value(self, amount, t);
        try self.print(", {d}, 64, true)", .{t.width});
    } else try expr.value(self, amount, t);
    try self.print(", {}, .{{ .local_per_unit = {d}, .global_per_local = {d} }})", .{ t.signed, scale.local_per_unit, scale.global_per_local });
}

/// Is driver `i` its net's value as is (`resolution.plainCopy`, with no delay)?
/// It stores the net itself; every other driver resolves in `rt.net`. A
/// logic gate is one on a scalar net: it never asserts §7.10.2's H/L.
/// Reads `select_forced`, which `native` fills before anything asks.
pub fn plainDriver(self: *const Emitter, i: u32) bool {
    const r = self.r;
    const d = r.drivers[i];
    const n = r.nets[d.net];
    const plain = switch (n.kind) {
        .wire, .tri, .uwire => true,
        .tri0, .tri1, .trireg, .wand, .wor, .triand, .trior, .supply0, .supply1, .wreal => false,
    };
    const source = switch (d.source) {
        .expr => true,
        .gate => |g| r.values[n.slot].width == 1 and logicGate(g.kind),
        .bridge, .udp, .mos, .pull => false,
    };
    return plain and source and r.netDrivers(d.net).len == 1 and !n.strength_read and n.cold == no_cold and !self.select_forced[n.slot] and
        d.s0 == .strong and d.s1 == .strong and !d.delay.present;
}

/// Is `kind` an and, or, xor, buf or not gate (or an inverse), not a
/// three-state `bufif`/`notif`, whose output can be z?
fn logicGate(kind: Ast.GateKind) bool {
    return switch (kind) {
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => true,
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => false,
    };
}

/// `net_ix`/`drv_ix`: a row for every net some driver of which is not
/// plain, and every net a switch reads the strength of (§7.12).
fn resolvedNets(self: *Emitter) Error!void {
    const r = self.r;
    self.net_ix = try self.arena.alloc(?u32, r.nets.len);
    self.drv_ix = try self.arena.alloc(?u32, r.drivers.len);
    @memset(self.net_ix, null);
    @memset(self.drv_ix, null);
    // A subset of the nets, and of their drivers, each once.
    try self.rt_nets.ensureTotalCapacityPrecise(self.arena, r.nets.len);
    try self.rt_drivers.ensureTotalCapacityPrecise(self.arena, r.drivers.len);
    for (r.nets, 0..) |n, k| {
        // §7.6 a switch terminal resolves with the nets it is joined to.
        const resolved = n.strength_read or r.netCold(n).trans.len != 0 or self.select_forced[n.slot] or for (r.netDrivers(@intCast(k))) |di| {
            if (!plainDriver(self, di)) break true;
        } else false;
        if (!resolved) continue;
        if (n.kind == .wreal) return self.refuse("a VAMS wreal net");
        self.net_ix[k] = @intCast(self.rt_nets.items.len);
        self.rt_nets.appendAssumeCapacity(@intCast(k));
        for (r.netDrivers(@intCast(k))) |di| {
            self.drv_ix[di] = @intCast(self.rt_drivers.items.len);
            self.rt_drivers.appendAssumeCapacity(di);
        }
    }
}

/// One `$dumpports` call: the pc it is at, its file and scopes
/// (`evcd.task`'s, resolved where it is emitted).
const PortFile = struct { pc: u32, name: []const u8, call: []const u8, scopes: []const u32 };

/// `evcd.task`'s arguments: a null-only list is none (§18.3.7's "name()").
fn portArgs(args: []const Ast.ExprId) []const Ast.ExprId {
    return if (args.len == 1 and args[0] == .none) &.{} else args;
}

/// §18.3.1 every `$dumpports` call's file and scopes, as `evcd.task` finds
/// them when it runs: what it reads of a port is its net's drivers and
/// their strengths, so each port's net keeps them (`strength_read`), and
/// resolves in `rt.net`.
fn portDumps(self: *Emitter) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    for (r.code.items, 0..) |ins, pc| {
        if (ins != .task or ins.task.task != .ports or ins.task.task.ports != .ports) continue;
        const t = ins.task;
        r.scope = r.code_scope.items[pc];
        const given = portArgs(t.args);
        var scopes: std.ArrayList(u32) = try .initCapacity(self.arena, @max(given.len, 1));
        var name: []const u8 = "dumpports.vcd";
        for (given, 0..) |e, i| {
            if (ex.tag(e) == .ident or ex.tag(e) == .hier_ident) switch (vcd.target(r, e) catch return self.refuse("a $dumpports scope the engine resolves only at run time")) {
                .scope => |sc| {
                    scopes.appendAssumeCapacity(sc);
                    continue;
                },
                .slot => {},
            };
            if (i + 1 != given.len) continue;
            if (ex.tag(e) != .str_literal) return self.refuse("a $dumpports file name held in a variable");
            name = r.file.str(ex.strOf(e));
        }
        if (scopes.items.len == 0) scopes.appendAssumeCapacity(r.instanceOf(r.scope));
        for (scopes.items) |sc| for (r.file.modules[r.scope_info.items[sc].def].ports) |mp| {
            const slot = r.names.get(.{ .scope = sc, .str = mp.name }) orelse continue;
            if (r.net_of.get(slot)) |n| r.nets[n].strength_read = true;
        };
        try self.port_files.append(self.arena, .{ .pc = @intCast(pc), .name = name, .call = vcd.callText(r.text, r.starts[t.tok]), .scopes = scopes.items });
    }
    if (self.port_files.items.len != 0) try self.xMeaning("§18.3 extended VCD, whose port states are strengths", null);
}

/// `rt.Design.ports_dump`: each `PortFile` with its header text and ports.
fn portTables(self: *Emitter) Error!void {
    const r = self.r;
    if (self.port_files.items.len == 0) return;
    try self.print("    .ports_dump = &.{{", .{});
    for (self.port_files.items) |f| {
        var head: std.Io.Writer.Allocating = .init(self.arena);
        const w = &head.writer;
        var ports: std.Io.Writer.Allocating = .init(self.arena);
        const pw = &ports.writer;
        var n: u32 = 0;
        // §18.4.2: "$scope module <full instance path> $end", then one
        // `$var port <size> <n> <name> $end` per port (`evcd.tick`).
        for (f.scopes) |sc| {
            w.writeAll("$scope module ") catch return error.OutOfMemory;
            root.for_emitter.evcd.path(r, w, sc) catch return error.OutOfMemory;
            w.writeAll(" $end\n") catch return error.OutOfMemory;
            for (r.file.modules[r.scope_info.items[sc].def].ports) |mp| {
                const slot = r.names.get(.{ .scope = sc, .str = mp.name }) orelse continue;
                const width = r.values[slot].width;
                w.writeAll("$var port ") catch return error.OutOfMemory;
                if (width == 1) w.writeAll("1") catch return error.OutOfMemory else {
                    const range = r.vecRange(slot);
                    w.print("[{d}:{d}]", .{ range.msb, range.lsb }) catch return error.OutOfMemory;
                }
                w.print(" <{d} {s} $end\n", .{ n, r.file.str(mp.name) }) catch return error.OutOfMemory;
                n += 1;
                pw.print("\n            .{{ .off = {d}, .width = {d}, .dir = .{t}, ", .{ self.off[slot], width, mp.direction }) catch return error.OutOfMemory;
                if (r.net_of.get(slot)) |k| {
                    pw.print(".net = {d}, .inside = &.{{", .{self.net_ix[k] orelse return self.refuse("a dumped port whose net the executable does not resolve")}) catch return error.OutOfMemory;
                    for (r.netDrivers(k)) |d| pw.print(" {},", .{root.for_emitter.evcd.below(r, r.drivers[d].scope, sc)}) catch return error.OutOfMemory;
                    pw.writeAll(" } },") catch return error.OutOfMemory;
                } else pw.writeAll("},") catch return error.OutOfMemory;
            }
            w.writeAll("$upscope $end\n") catch return error.OutOfMemory;
        }
        w.writeAll("$enddefinitions $end\n") catch return error.OutOfMemory;
        try self.print("\n        .{{ .name = \"{f}\", .call = \"{f}\", .finest = {d}, .header = \"{f}\", .ports = &.{{{s}\n        }} }},", .{
            std.zig.fmtString(f.name), std.zig.fmtString(f.call), r.finest, std.zig.fmtString(head.written()), ports.written(),
        });
    }
    try self.print("\n    }},\n", .{});
}

/// One §18.3 task at `pc` (`evcd.task`): a `$dumpports` call selects its
/// file; the others act on the file their last argument names, or on
/// every file. A name no `$dumpports` gives is ignored.
fn portTask(self: *Emitter, pc: u32, op: root.for_emitter.evcd.Op, args: []const Ast.ExprId) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    if (op == .ports) {
        for (self.port_files.items, 0..) |f, k| if (f.pc == pc) return self.print("            try s.portsSelect({d});\n", .{k});
        unreachable; // `portDumps` listed every call
    }
    const given = portArgs(args);
    var k: ?usize = null;
    if (given.len != 0 and (op != .limit or given.len == 2)) {
        const e = given[given.len - 1];
        if (ex.tag(e) != .str_literal) return self.refuse("a §18.3 file name held in a variable");
        const name = r.file.str(ex.strOf(e));
        k = for (self.port_files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) break i;
        } else return;
    }
    try self.print("            try s.portsControl(.{t}, {?d}, ", .{ op, k });
    if (op == .limit) {
        try self.print("std.math.lossyCast(u64, ", .{});
        try int(self, given[0]);
        try self.print("));\n", .{});
    } else try self.print("0);\n", .{});
}

/// Numbers the distinct selects the code forces (§9.3.2), slot by slot and
/// in code order within a slot, into `parts` and `part_start`: a net may
/// have any number of them.
fn forcedParts(self: *Emitter) Error!void {
    const r = self.r;
    const start = try self.arena.alloc(u32, r.values.len + 1);
    @memset(start, 0);
    // First each one's place within its slot, counted in `start[slot + 1]`.
    for (r.code.items) |ins| if (ins == .override_on) if (ins.override_on.bits) |b| {
        const slot = ins.override_on.slot;
        const gop = try self.parts.getOrPut(self.arena, .{ .slot = slot, .bits = b });
        if (gop.found_existing) continue;
        gop.value_ptr.* = start[slot + 1];
        start[slot + 1] += 1;
    };
    for (1..start.len) |i| start[i] += start[i - 1];
    var it = self.parts.iterator();
    while (it.next()) |e| e.value_ptr.* += start[e.key_ptr.slot];
    self.part_start = start;
}

/// The row in `rt.State.parts` of `slot`'s forced select `sel` (§9.3.2);
/// null when no `force` names it.
fn partOf(self: *Emitter, slot: u32, sel: compile.Bits) ?u32 {
    return self.parts.get(.{ .slot = slot, .bits = sel });
}

/// `rt.Design.nets`/`drivers`/`udps`: `Run.nets` and `Run.drivers` of the
/// `resolvedNets` rows, as `rt.net` reads them.
fn netTables(self: *Emitter) Error!void {
    const r = self.r;
    if (self.rt_nets.items.len == 0) return;
    var conds: u32 = 0;
    try self.print("    .nets = &.{{", .{});
    for (self.rt_nets.items) |k| {
        const n = r.nets[k];
        const c = r.netCold(n);
        var strong = !n.strength_read and c.trans.len == 0;
        for (r.netDrivers(k)) |di| {
            const d = r.drivers[di];
            const or_z = switch (d.source) {
                .gate => |g| !logicGate(g.kind),
                .mos => true,
                .expr, .bridge, .udp, .pull => false,
            };
            strong = strong and !or_z and d.s0 == .strong and d.s1 == .strong;
        }
        try self.print("\n        .{{ .kind = .{t}, .slot = {d}, .off = {d}, .width = {d}, .drivers = &.{{", .{ n.kind, n.slot, self.off[n.slot], r.values[n.slot].width });
        for (r.netDrivers(k)) |di| try self.print(" {d},", .{self.drv_ix[di].?});
        try self.print(" }}, .strong = {}, .delay = {f}, .charge = .{t}, .decay = {?d}", .{ strong, fmtDelay(c.delay), n.charge, c.decay });
        if (c.paths.len == 0) {
            try self.print(" }},", .{});
            continue;
        }
        // §14.3 its module paths, a condition as `pathCond<i>` in `pathConds`' order.
        try self.print(", .paths = &.{{", .{});
        for (c.paths) |p| {
            try self.print("\n            .{{ .src = {d}, .src_off = {d}, .src_bit = {d}, .edge = .{t}, .ifnone = {}, .cond = ", .{ p.src, self.off[p.src], p.src_bit, p.edge, p.ifnone });
            if (p.cond != .none) {
                try self.print("&Code(false).pathCond{d}", .{conds});
                conds += 1;
            } else try self.print("null", .{});
            try self.print(", .table = .{{", .{});
            for (p.table) |row| try self.print(" .{{ {d}, {d}, {d}, {d} }},", .{ row[0], row[1], row[2], row[3] });
            try self.print(" }} }},", .{});
        }
        try self.print(" }} }},", .{});
    }
    try self.print("\n    }},\n    .drivers = &.{{", .{});
    var udps: std.ArrayList(*const root.for_emitter.net.Udp) = try .initCapacity(self.arena, self.rt_drivers.items.len);
    for (self.rt_drivers.items) |di| {
        const d = r.drivers[di];
        r.scope = d.scope;
        try self.print("\n        .{{ .net = {d}, .s0 = .{t}, .s1 = .{t}, .delay = {f}, .init = .{t}, .delay_bit = ", .{ self.net_ix[d.net].?, d.s0, d.s1, fmtDelay(d.delay), d.current.bit(if (d.source == .udp) d.source.udp.out_bit orelse 0 else 0) });
        switch (d.source) {
            .expr => try self.print("null, .source = .expr }},", .{}),
            .gate => |g| try self.print("{d}, .source = .{{ .gate = {d} }} }},", .{ g.out_bit orelse 0, g.out_bit orelse 0 }),
            .udp => |u| {
                try self.print("{d}, .source = .{{ .udp = {d} }} }},", .{ u.out_bit orelse 0, udps.items.len });
                udps.appendAssumeCapacity(u);
            },
            .mos => |m| {
                if (m.lane != null or m.out_bit != null) return self.refuse("§7.1.6 a MOS switch of an instance array with vector terminals (one lane each)");
                var data_net: ?u32 = null;
                if (r.file.exprs.tag(m.data) == .ident) if (r.net_of.get(try self.slot(m.data))) |net| {
                    data_net = self.net_ix[net];
                };
                try self.print("0, .source = .{{ .mos = .{{ .n_type = {}, .resistive = {}, .data_net = {?d} }} }} }},", .{ m.n_type, m.resistive, data_net });
            },
            .bridge => |b| try self.print("0, .source = .{{ .bridge = .{{ .src_off = {d}, .src_lo = {d}, .dst_lo = {d}, .width = {d} }} }} }},", .{ self.off[b.src], b.src_lo, b.dst_lo, b.width }),
            .pull => |b| try self.print("0, .source = .{{ .pull = .{t} }} }},", .{b}),
        }
    }
    try self.print("\n    }},\n", .{});
    if (r.trans.len != 0) {
        try self.print("    .trans = &.{{", .{});
        for (r.trans) |t| try self.print("\n        .{{ .a = {d}, .b = {d}, .a_bit = {d}, .b_bit = {d}, .on = .{t}, .state = .{t}, .resistive = {}, .delay = {f} }},", .{
            self.net_ix[t.a].?, self.net_ix[t.b].?, t.a_bit, t.b_bit, t.on, t.state, t.resistive, fmtDelay(t.delay),
        });
        try self.print("\n    }},\n", .{});
    }
    if (udps.items.len == 0) return;
    try self.print("    .udps = &.{{", .{});
    for (udps.items) |u| {
        try self.print("\n        .{{ .sequential = {}, .ins = {d}, .state = .{t}, .rows = &.{{", .{ u.sequential, u.ins.len, u.state });
        for (u.rows) |row| {
            try self.print("\n            .{{ .state = {d}, .out = {d}, .edge_at = {?d}, .ins = &.{{", .{ row.state, row.out, row.edge_at });
            for (row.ins) |sym| switch (sym) {
                .level => |c| try self.print(" .{{ .level = {d} }},", .{c}),
                .pair => |pr| try self.print(" .{{ .pair = .{{ {d}, {d} }} }},", .{ pr[0], pr[1] }),
                .letter => |c| try self.print(" .{{ .letter = {d} }},", .{c}),
            };
            try self.print(" }} }},", .{});
        }
        try self.print("\n        }} }},", .{});
    }
    try self.print("\n    }},\n", .{});
}

fn fmtDelay(d: root.for_emitter.net.Delay) std.fmt.Alt(root.for_emitter.net.Delay, delayText) {
    return .{ .data = d };
}

fn delayText(d: root.for_emitter.net.Delay, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print(".{{ .rise = {d}, .fall = {d}, .off = {d}, .present = {} }}", .{ d.rise, d.fall, d.off, d.present });
}

/// `.continuous` (`exec`'s arm): driver `i`'s value. A plain driver stores
/// its net (`resolution.plainCopy`); any other hands its value to `rt.net`, which
/// delays it (§6.1.3) or resolves the net (§7.9). Then it re-arms on its
/// operands.
fn continuous(self: *Emitter, pc: u32, i: u32) Error!void {
    const r = self.r;
    const d = r.drivers[i];
    const n = r.nets[d.net];
    r.scope = d.scope;
    const nw = self.slotWidth(n.slot);
    if (plainDriver(self, i)) {
        if (self.role == .comb and self.pure_nodes[self.role.comb]) {
            // Only the time-0 queue runs this process (`plan.Role.comb`):
            // one out-of-line store serves every node of its width.
            if (self.watched[n.slot])
                try self.print("            try M.putCold(s, {f}, {d}, {d}, ", .{ fmtReach(self.reach[n.slot]), n.slot, self.off[n.slot] })
            else
                try self.print("            try M.setCold(s, {d}, ", .{self.off[n.slot]});
            try self.print("val{d}(s.view()), {f});\n            return;\n", .{ self.role.comb, full(nw) });
            return;
        }
        if (d.source == .gate) try planes(self, d.source.gate.ins, d.source.gate.lane);
        try self.print("            ", .{});
        try self.store(n.slot, .blocking);
        switch (d.source) {
            .expr => |x| try driverValue(self, x.e, x.slice, n.slot),
            .gate => |g| try gateLogic(self, g.kind, g.ins.len),
            .bridge, .udp, .mos, .pull => unreachable, // `plainDriver` admits these two
        }
        try self.print(", {f});\n", .{full(nw)});
    } else {
        const k = self.drv_ix[i].?;
        // `--two-state` keeps a delay or a logic gate: neither gives an x
        // or z meaning. Strength, several drivers, three states do.
        if (self.caresX()) {
            const two_ok = switch (n.kind) {
                .wire, .tri, .uwire => r.netDrivers(d.net).len == 1 and !n.strength_read and r.netCold(n).trans.len == 0 and d.s0 == .strong and d.s1 == .strong,
                .tri0, .tri1, .trireg, .wand, .wor, .triand, .trior, .supply0, .supply1, .wreal => false,
            } and switch (d.source) {
                .expr => true,
                .gate => |g| logicGate(g.kind),
                .udp, .mos, .bridge, .pull => false,
            };
            if (!two_ok) try self.xMeaning("a §7.9 net resolved from strengths or several drivers, or a three-state, switch, UDP, port-window or pull driver", null);
            // §7.14 picks the delay by the value transitioned to: with
            // three different ones, an x or z decides when a value lands.
            for ([_]root.for_emitter.net.Delay{ d.delay, r.netCold(n).delay }) |dl| if (dl.present and (dl.rise != dl.fall or dl.fall != dl.off))
                try self.xMeaning("a `delay3` whose rise, fall and turn-off differ, chosen by an x or z", null);
        }
        switch (d.source) {
            .expr => |x| {
                try self.print("            const p = L.planesOf(", .{});
                try driverValue(self, x.e, x.slice, n.slot);
                try self.print(");\n            try s.drive({d}, &p, false);\n", .{k});
            },
            .gate => |g| {
                try bits(self, g.ins, g.lane);
                try self.print("            try s.gate({d}, .{t}, &b);\n", .{ k, g.kind });
            },
            .udp => |u| {
                try bits(self, u.ins, u.lane);
                try self.print("            try s.udp({d}, &b);\n", .{k});
            },
            .mos => |m| {
                if (nw != 1) return self.refuse("a MOS switch driving a vector");
                try bits(self, &.{ m.data, m.gate }, null);
                try self.print("            try s.mos({d}, b[0], b[1]);\n", .{k});
            },
            .bridge => try self.print("            try s.bridge({d});\n", .{k}),
            .pull => try self.print("            try s.pull({d});\n", .{k}),
        }
    }
    // A node is run by its settle event, not re-queued by its operands.
    if (self.role != .comb) try self.print("            s.armed[{d}] = true;\n", .{pc});
    try self.print("            return;\n", .{});
}

/// A continuous assignment's value in its net's type; with `slice`, the
/// window of a §12.3.6 concatenated port it asserts.
fn driverValue(self: *Emitter, e: Ast.ExprId, slice: ?root.for_emitter.net.Slice, net_slot: u32) Error!void {
    if (slice) |sl| {
        const t = compile.typeOf(self.r, e);
        const ctx: Type = .{ .width = @max(t.width, sl.total), .signed = t.signed };
        try self.print("L.part(", .{});
        try expr.value(self, e, ctx);
        return self.print(", {d}, {d}, {d})", .{ sl.lo, self.slotWidth(net_slot), ctx.width });
    }
    try expr.assigned(self, e, self.r.slotType(net_slot));
}

/// `const w<j>`: bit `lane` (0 without one) of each terminal in `ins`, as
/// a one-bit value.
fn planes(self: *Emitter, ins: []const Ast.ExprId, lane: ?u32) Error!void {
    for (ins, 0..) |in, j| {
        const nt = compile.typeOf(self.r, in);
        try self.print("            const w{d} = ", .{j});
        // `selfDetermined` reads a real as a 64-bit integer.
        if (nt.real or nt.width > 1) try self.print("L.part(", .{});
        const t = try expr.selfDetermined(self, in);
        if (t.width > 1) try self.print(", {d}, 1, {d})", .{ lane.?, t.width });
        try self.print(";\n", .{});
    }
}

/// A plain logic gate's output from `planes`' `n` inputs: §7.8.5's tables
/// for these eight are the §5.1.10 bitwise operators folded from their
/// identity, which read z as x as the tables do.
fn gateLogic(self: *Emitter, kind: Ast.GateKind, n: usize) Error!void {
    const op, const invert = switch (kind) {
        .g_and, .g_buf => .{ "and", false },
        .g_nand => .{ "and", true },
        .g_or => .{ "or", false },
        .g_nor => .{ "or", true },
        .g_xor => .{ "xor", false },
        .g_xnor, .g_not => .{ "xor", true },
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => unreachable, // `plainDriver` admits none
    };
    if (invert) try self.print("L.not(", .{});
    for (0..n) |_| try self.print("L.bitwise(.@\"{s}\", ", .{op});
    try self.print("L.k({d}, 0)", .{@intFromBool(std.mem.eql(u8, op, "and"))});
    for (0..n) |j| try self.print(", w{d}, 1)", .{j});
    if (invert) try self.print(", 1)", .{});
}

/// `const b`: bit `lane` (0 without one) of each terminal in `ins`, as
/// `resolution.gateValue` reads it.
fn bits(self: *Emitter, ins: []const Ast.ExprId, lane: ?u32) Error!void {
    for (ins, 0..) |in, j| {
        try self.print("            const in{d} = ", .{j});
        const t = try expr.selfDetermined(self, in);
        try self.print(";\n", .{});
        if (t.width > 1) try self.print("            const bit{d} = L.low(L.part(in{d}, {d}, 1, {d}));\n", .{ j, j, lane.?, t.width }) else try self.print("            const bit{d} = L.low(in{d});\n", .{ j, j });
    }
    try self.print("            const b = [_]L.Bit{{", .{});
    for (0..ins.len) |j| try self.print(" bit{d},", .{j});
    try self.print(" }};\n", .{});
}

/// `evaluate.assignInt`: the Zig `i64` `v` assigned to `target`, through a
/// scratch word past the slots'.
pub fn assignInt(self: *Emitter, target: Ast.ExprId, v: []const u8) Error!void {
    try assignWord(self, target, try self.arena.print("L.k(@bitCast(@as(i64, {s})), 0)", .{v}), .{ .width = 64, .signed = true });
}

/// The 64-bit `L.T(64)` text `word`, typed `ty` (a signed 64-bit integer or
/// a real's bits), assigned to `target` (`evaluate.assign`/`assignReal`).
pub fn assignWord(self: *Emitter, target: Ast.ExprId, word: []const u8, ty: Type) Error!void {
    const at = try cellOf(self, std.math.maxInt(u32), 64);
    try self.print("            try M.set(s, {d}, {s}, 0x{x});\n", .{ at, word, std.math.maxInt(u64) });
    try assignment(self, target, .{ .stored = .{ .off = at, .ty = ty } }, .blocking);
}

/// `system.stringValue` of the Zig `[]const u8` `v` assigned to `target`,
/// through a scratch cell as wide as the target (§17.2.3: "the string
/// assignment to variable rules").
pub fn assignChars(self: *Emitter, target: Ast.ExprId, v: []const u8) Error!void {
    // A real takes the characters' low 64 bits as an unsigned number.
    const tt = try targetType(self, target);
    const w = if (tt.real) 64 else tt.width;
    const at = try cellOf(self, std.math.maxInt(u32) - words(w), w);
    try self.print("            s.setChars({d}, {d}, {s});\n", .{ at, w, v });
    try assignment(self, target, .{ .stored = .{ .off = at, .ty = .{ .width = w, .signed = false } } }, .blocking);
}

/// §17.2.4.4 `$fread`: a packed target takes one binary word; an entire
/// memory takes words from the requested (or lowest) address upward. Stores
/// use the ordinary assignment path so observers wake for changed values.
pub fn fread(self: *Emitter, args: []const Ast.ExprId) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const lb = self.label();
    const base = if (ex.tag(args[0]) == .ident) try self.slot(args[0]) else null;
    const arr = if (base) |at| r.arrays.get(at) else null;
    try self.print("fr{d}: {{\n            const fd{d} = ", .{ lb, lb });
    try int64(self, args[1]);
    try self.print(";\n", .{});
    if (arr) |memory| {
        const at = base.?;
        const width = self.slotWidth(at);
        try self.print("            const first{d}: i64 = ", .{lb});
        if (args.len > 2 and args[2] != .none) {
            try int64(self, args[2]);
            try self.print(" orelse break :fr{d} L.k(0, 0)", .{lb});
        } else try self.print("{d}", .{memory.low});
        try self.print(";\n            const count{d}: i64 = ", .{lb});
        if (args.len > 3) {
            try int64(self, args[3]);
            try self.print(" orelse break :fr{d} L.k(0, 0)", .{lb});
        } else try self.print("{d}", .{memory.count});
        try self.print(";\n            if (first{d} < {d} or first{d} > {d} or count{d} <= 0) break :fr{d} L.k(0, 0);\n", .{ lb, memory.low, lb, memory.high, lb, lb });
        try self.print("            const n{d}: u32 = @intCast(@min(count{d}, {d} - first{d} + 1));\n            var read{d}: i64 = 0;\n            for (0..n{d}) |k{d}| {{\n", .{ lb, lb, memory.high, lb, lb, lb, lb });
        try self.print("            const a{d}: u32 = {d} + @as(u32, @intCast(first{d} - {d})) + @as(u32, @intCast(k{d}));\n", .{ lb, at, lb, memory.low, lb });
        try self.print("            const word{d} = try s.fileWord(fd{d}, {d});\n            read{d} += word{d}.n;\n            const v{d} = word{d}.value orelse break;\n            ", .{ lb, lb, width, lb, lb, lb, lb });
        try self.storeElement(at, lb, .blocking);
        try self.print("v{d}, {f});\n            }}\n            break :fr{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(read{d})))), 0);\n            }}", .{ lb, full(width), lb, lb });
    } else {
        const ty = try targetType(self, args[0]);
        try self.print("            const word{d} = try s.fileWord(fd{d}, {d});\n            if (word{d}.value) |v{d}| {{\n", .{ lb, lb, ty.width, lb, lb });
        try assignment(self, args[0], .{ .evaluated = .{ .label = lb, .ty = .{ .width = ty.width, .signed = false } } }, .blocking);
        try self.print("            }}\n            break :fr{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(word{d}.n)))), 0);\n            }}", .{ lb, lb });
    }
}

/// `evaluate.eval(e, 0).asInt()` as a Zig `?i64`.
pub fn int64(self: *Emitter, e: Ast.ExprId) Error!void {
    try self.print("L.asInt(", .{});
    const t = try expr.selfDetermined(self, e);
    try self.print(", {d}, {})", .{ t.width, t.signed });
}

/// `evaluate.eval(e, 0).asInt() orelse 0` as a Zig `i64`.
fn int(self: *Emitter, e: Ast.ExprId) Error!void {
    try self.print("(L.asInt(", .{});
    const t = try expr.selfDetermined(self, e);
    try self.print(", {d}, {}) orelse 0)", .{ t.width, t.signed });
}

/// Text the interpreter prints from `r` alone at this pc (`%m`,
/// `$printtimescale`), captured once and written as a literal.
fn staticText(self: *Emitter, comptime f: anytype, args: anytype) Error![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(self.arena);
    const saved = self.r.out;
    self.r.out = &buf.writer;
    defer self.r.out = saved;
    @call(.auto, f, .{self.r} ++ args) catch return self.refuse("text the engine prints only at run time");
    return buf.written();
}

/// `display.display` walked at compile time: literal text is written as is,
/// and each conversion becomes one call on its operand (§17.1, Table 9-22).
/// With `only_first`, `display.sformat`'s walk of a literal format.
fn show(self: *Emitter, args: []const Ast.ExprId, sh: display.Show, only_first: bool) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    var text: std.ArrayList(u8) = .empty;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (only_first and arg != 0) {
            try flush(self, &text);
            try self.print("            s.warn(\"W1153\", \"{f}\", .{{}});\n", .{std.zig.fmtString(display.sformat_mismatch)});
            return;
        }
        if (e == .none) {
            try text.append(self.arena, ' ');
            continue;
        }
        if (ex.tag(e) != .str_literal) {
            try flush(self, &text);
            try operand(self, e, sh.radix, null);
            continue;
        }
        const format = r.file.str(ex.strOf(e));
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] != '%') {
                try text.append(self.arena, format[i]);
                continue;
            }
            i += 1;
            if (format[i] == '%') {
                try text.append(self.arena, '%');
                continue;
            }
            // `display.walk` validated this format: every flag left is one
            // `fmt.flagVerdict` admits, so only a real conversion carries one.
            const sp = fmt.spec(format, &i);
            const width = sp.width;
            const precision = sp.precision;
            switch (format[i]) {
                'b', 'B', 'o', 'O', 'h', 'H', 'd', 'D' => {
                    arg += 1;
                    try flush(self, &text);
                    try operand(self, args[arg], switch (format[i]) {
                        'b', 'B' => .binary,
                        'o', 'O' => .octal,
                        'h', 'H' => .hex,
                        else => .decimal,
                    }, width);
                },
                't', 'T' => {
                    arg += 1;
                    try flush(self, &text);
                    // A real operand is formatted as it is (#64).
                    if (compile.typeOf(r, args[arg]).real) {
                        try self.print("            try s.timeReal(", .{});
                        try expr.real(self, args[arg]);
                        try self.print(", {d}, {?d});\n", .{ r.timeOf(r.scope).unit_exp, width });
                    } else {
                        try self.print("            try s.time(", .{});
                        const t = try expr.selfDetermined(self, args[arg]);
                        try self.print(", {d}, {}, {d}, {?d});\n", .{ t.width, t.signed, r.timeOf(r.scope).unit_exp, width });
                    }
                },
                's', 'S', 'c', 'C' => {
                    arg += 1;
                    try flush(self, &text);
                    try self.print("            try s.text(", .{});
                    const t = try expr.selfDetermined(self, args[arg]);
                    try self.print(", {d}, {}, {?d});\n", .{ t.width, format[i] == 'c' or format[i] == 'C', width });
                },
                'm', 'M' => try text.appendSlice(self.arena, try staticText(self, display.emitScope, .{})),
                'l', 'L' => {
                    const def = r.scope_info.items[r.scope].def;
                    try text.appendSlice(self.arena, try self.arena.print("{s}.{s}", .{ r.file.str(r.def_lib[def]), r.file.str(r.file.modules[def].name) }));
                },
                // §17.1.1.2 Table 17-3's real conversions, and §9.4.7's %r.
                'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R' => {
                    arg += 1;
                    try flush(self, &text);
                    try self.print("            try s.real(", .{});
                    try expr.real(self, args[arg]);
                    try self.print(", '{c}', {d}, {d}, {?d});\n", .{ format[i], sp.flags, precision, width });
                },
                'v', 'V' => {
                    arg += 1;
                    try flush(self, &text);
                    try strengthOf(self, args[arg]);
                },
                'u', 'U', 'z', 'Z' => return self.refuse("§17.1.1.2 %u/%z: unformatted (binary) display output"),
                else => return self.refuse("a display conversion the engine refuses"),
            }
        }
    }
    if (sh.newline) try text.append(self.arena, '\n');
    try flush(self, &text);
}

/// §17.1.1.5 `%v` of `e`, which `display.walk` proved a scalar: a net's
/// resolved signal (`display.walk` marked it `strength_read`, so it has a
/// `net_ix` row whose fold keeps it), an undriven net's own pull, else the
/// value at strong strength.
fn strengthOf(self: *Emitter, e: Ast.ExprId) Error!void {
    const r = self.r;
    const net = if (r.file.exprs.tag(e) == .ident) r.net_of.get(try self.slot(e)) else null;
    if (net) |k| {
        // §7.6: a pass switch drives a net with no driver of its own
        // (`display.walk`'s test, which the interpreter prints by).
        if (r.netDrivers(k).len == 0 and r.netCold(r.nets[k]).trans.len == 0) {
            var buf: std.Io.Writer.Allocating = .init(self.arena);
            display.strength(&buf.writer, root.for_emitter.net.netPull(r.nets[k].kind)) catch return error.OutOfMemory;
            return self.print("            try s.out.writeAll(\"{s}\");\n", .{buf.written()});
        }
        const ix = self.net_ix[k] orelse return self.refuse("a %v of a net the executable does not resolve");
        return self.print("            try s.netStrength({d});\n", .{ix});
    }
    try self.print("            try s.strongStrength(", .{});
    const t = try expr.selfDetermined(self, e);
    try self.print(", {d});\n", .{t.width});
}

/// §17.2.3 `$sformat` of a format held in a variable (`display.sformat`'s
/// dynamic walk): the format is read when the task runs, and each argument
/// is evaluated by whichever conversion it meets there.
fn dynamicFormat(self: *Emitter, args: []const Ast.ExprId) Error!void {
    const r = self.r;
    for (args[1..]) |a| {
        if (a == .none) return self.refuse("a null argument after a $sformat format held in a variable");
        // Its strength is kept only where a literal %v marks it read.
        if (r.file.exprs.tag(a) == .ident and r.net_of.get(try self.slot(a)) != null and compile.typeOf(r, a).width == 1)
            return self.refuse("a scalar net after a $sformat format held in a variable, which a %v there would need the strength of");
    }
    if (compile.typeOf(r, args[0]).real) return self.refuse("a $sformat format held in a real");
    const scope = std.zig.fmtString(try staticText(self, display.emitScope, .{}));
    const def = r.scope_info.items[r.scope].def;
    const lib = std.zig.fmtString(try self.arena.print("{s}.{s}", .{ r.file.str(r.def_lib[def]), r.file.str(r.file.modules[def].name) }));
    const lb = self.label();
    try self.print("            {{\n            var fb{d}: [{d}]u8 = undefined;\n            var f{d} = S.formatOf(&fb{d}, ", .{ lb, (compile.typeOf(r, args[0]).width + 7) / 8, lb, lb });
    const ft = try expr.selfDetermined(self, args[0]);
    try self.print(", {d});\n            b{d}: {{\n", .{ ft.width, lb });
    for (args[1..], 1..) |a, k| {
        try self.print("            const c{d}_{d} = (try s.nextSpec(&f{d}, \"{f}\", \"{f}\")) orelse break :b{d};\n", .{ lb, k, lb, scope, lib, lb });
        try self.print("            switch (c{d}_{d}.conv) {{\n                'b', 'B', 'o', 'O', 'h', 'H', 'd', 'D' => try s.value(", .{ lb, k });
        var t = try expr.selfDetermined(self, a);
        try self.print(", {d}, {}, switch (c{d}_{d}.conv) {{\n                    'b', 'B' => .binary,\n                    'o', 'O' => .octal,\n                    'h', 'H' => .hex,\n                    else => .decimal,\n                }}, c{d}_{d}.width),\n", .{ t.width, t.signed, lb, k, lb, k });
        if (compile.typeOf(r, a).real) {
            try self.print("                't', 'T' => try s.timeReal(", .{});
            try expr.real(self, a);
            try self.print(", {d}, c{d}_{d}.width),\n", .{ r.timeOf(r.scope).unit_exp, lb, k });
        } else {
            try self.print("                't', 'T' => try s.time(", .{});
            t = try expr.selfDetermined(self, a);
            try self.print(", {d}, {}, {d}, c{d}_{d}.width),\n", .{ t.width, t.signed, r.timeOf(r.scope).unit_exp, lb, k });
        }
        try self.print("                's', 'S', 'c', 'C' => try s.text(", .{});
        t = try expr.selfDetermined(self, a);
        try self.print(", {d}, c{d}_{d}.conv == 'c' or c{d}_{d}.conv == 'C', c{d}_{d}.width),\n", .{ t.width, lb, k, lb, k, lb, k });
        if (compile.typeOf(r, a).width == 1) {
            try self.print("                'v', 'V' => try s.strongStrength(", .{});
            t = try expr.selfDetermined(self, a);
            try self.print(", {d}),\n", .{t.width});
        } else try self.print("                'v', 'V' => return s.fail(\"§17.1.1.5: %v takes a scalar net reference\", .{{}}),\n", .{});
        try self.print("                else => try s.real(", .{});
        try expr.real(self, a);
        try self.print(", c{d}_{d}.conv, c{d}_{d}.flags, c{d}_{d}.precision, c{d}_{d}.width),\n            }}\n", .{ lb, k, lb, k, lb, k, lb, k });
    }
    try self.print("            try s.endFormat(&f{d}, \"{f}\", \"{f}\");\n            }}\n            }}\n", .{ lb, scope, lib });
}

fn flush(self: *Emitter, text: *std.ArrayList(u8)) Error!void {
    if (text.items.len == 0) return;
    try self.print("            try s.out.writeAll(\"{f}\");\n", .{std.zig.fmtString(text.items)});
    text.clearRetainingCapacity();
}

/// One `%b %o %h %d` operand, or an argument with no format.
fn operand(self: *Emitter, e: Ast.ExprId, radix: fmt.Radix, width: ?u64) Error!void {
    try self.print("            try s.value(", .{});
    const t = try expr.selfDetermined(self, e);
    try self.print(", {d}, {}, .{t}, {?d});\n", .{ t.width, t.signed, radix, width });
}

test words {
    try std.testing.expectEqual(@as(u32, 0), words(0));
    try std.testing.expectEqual(@as(u32, 1), words(64));
    try std.testing.expectEqual(@as(u32, 2), words(65));
}
