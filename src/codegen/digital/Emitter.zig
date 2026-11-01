//! One emission's state: the elaborated `Run` it reads (never runs), the Zig
//! text written so far, and the tables every stage of the emission shares
//! (the plane layout, the `rt.net` rows, the plan, the worklists). In: a
//! `Run` and the caller's arena. Out: nothing by itself; `native.zig` drives
//! the stages that write through it.
//! Cites: IEEE 1364-2005 §3.2 (x and z), §4.1 (4-state logic), §10 (the
//! subroutines a call reaches).
//!
//! Contents:
//! - `pub const Error = error{ Unsupported, OutOfMemory }`
//! - `pub const Logic = enum { auto, two, four }`
//! - `pub const Target = enum { executable, device }`
//! - `pub const Reason = struct`
//! - `pub const Site = struct`
//! - `pub const EventSelect = struct`
//! - `pub fn init(arena: Allocator, r: *Run, target: Target, logic: Logic) Emitter`
//! - `pub fn print(em: *Emitter, comptime f: []const u8, args: anytype) Error!void`
//! - `pub fn refuse(em: *Emitter, why: []const u8) error{Unsupported}`
//! - `pub fn caresX(em: *const Emitter) bool`
//! - `pub fn xMeaning(em: *Emitter, why: []const u8, tok: ?u32) Error!void`
//! - `pub fn keepFour(em: *Emitter, why: []const u8, tok: ?u32) void`
//! - `pub fn label(em: *Emitter) u32`
//! - `pub fn fits(em: *Emitter, t: Type) Error!void`
//! - `pub fn get(em: *Emitter, at: u32) Error!void`
//! - `pub fn slot(em: *Emitter, e: Ast.ExprId) Error!u32`
//! - `pub fn slotWidth(em: *const Emitter, at: u32) u32`
//! - `pub fn element(em: *Emitter, e: Ast.ExprId) Error!bool`
//! - `pub fn insert(em: *Emitter, at: usize, text: []const u8) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const Run = sim_digital.Run;
const Type = sim_digital.for_emitter.compile.Type;
const layout = @import("layout.zig");
const nets = @import("nets.zig");
const plan = @import("plan.zig");
const plane_words = @import("plane_words.zig");

r: *Run,
arena: Allocator,
out: std.Io.Writer.Allocating,
target: Target,
logic: Logic,
/// Under `.auto`, the first reason the design keeps x or z meaning.
four: ?Reason = null,
/// Why the design is not native, once something refused (static text).
why: []const u8 = "",
/// The last number `label` gave out.
labels: u32 = 0,
/// Each slot's plane words and the cells past them (`layout.zig`).
planes: layout.Planes = .{},
/// §10.3 per `disable` target, the pcs its process resumes at.
block_ends: layout.BlockEnds = .{},
/// §9.3.2 the forced selects and the slots some `force` holds a select of.
forced: layout.ForcedParts = .{},
/// The nets `rt.net` resolves and their drivers (`nets.zig`).
rt: nets.Rows = .{},
/// §18.3 each `$dumpports` call.
port_files: []const nets.PortFile = &.{},
/// `plan.Plan.watched` and `plan.Plan.reach`, per slot.
watched: []const bool = &.{},
reach: []const plan.Reach = &.{},
/// Per settle node: its pc continuously assigns a pure value (`settle.zig`).
pure_nodes: []const bool = &.{},
/// What the process being emitted is.
site: Site = .{},
/// The subroutines a call reached (§10), each emitted once as
/// `fn proc<entry>` after the processes; `sub_seen` has their bits.
subs_todo: std.ArrayList(u32) = .empty,
sub_seen: std.DynamicBitSetUnmanaged = .{},
/// The tasks whose out-of-line body a `.call_timed` reached (§10.2.3).
timed: std.ArrayList(u32) = .empty,
/// Indexed named-event controls, each emitted as `fn eventSelect<i>`.
event_selects: std.ArrayList(EventSelect) = .empty,
/// The pc of each `$strobe`/`$monitor` site, in `rt.show_base` order.
shows: std.ArrayList(u32) = .empty,

/// `Unsupported`: a construct is not native; `Emitter.why` names it, and
/// `program` falls back to the interpreter (`device` refuses). Either error
/// leaves the text written so far meaningless.
pub const Error = error{
    /// A construct the native runtime cannot run (`why` names it).
    Unsupported,
    /// The arena could not grow.
    OutOfMemory,
};

/// Which logic the executable computes: IEEE 1364's 4-state; `--two-state`'s,
/// where every x or z is 0 (`rt.logic.two`); or 4-state that turns 2-state
/// once no live x or z is left (`rt.auto`), which prints what 4-state prints.
pub const Logic = enum { auto, two, four };

/// What the emitted root is: an `--emit-exe` executable, or a contract
/// device an analog host loads (`rt.Device`).
pub const Target = enum { executable, device };

/// Why a design keeps x or z meaning, and the token where it does.
pub const Reason = struct { why: []const u8, tok: ?u32 };

/// The process being emitted: its scheduling role, and whether it is a
/// subroutine body, where every step first checks for a `disable`
/// unwinding it (§10.3).
pub const Site = struct { role: plan.Role = .general, in_sub: bool = false };

/// §9.7.3 an indexed named-event term and the lexical scope its selector
/// reads when an element occurs.
pub const EventSelect = struct { e: Ast.ExprId, scope: u32 };

const Emitter = @This();

/// Returns a fresh emission over `r` into `arena`; `r` must outlive it.
pub fn init(arena: Allocator, r: *Run, target: Target, logic: Logic) Emitter {
    // A device is 4-state: its host owns time, which `auto` would rerun.
    if (target == .device) assert(logic == .four);
    const em: Emitter = .{ .r = r, .arena = arena, .out = .init(arena), .target = target, .logic = logic };
    assert(em.out.writer.end == 0);
    return em;
}

/// Appends formatted Zig text to `out`; a writer failure is OOM.
pub fn print(em: *Emitter, comptime f: []const u8, args: anytype) Error!void {
    const before = em.out.written().len;
    em.out.writer.print(f, args) catch return error.OutOfMemory;
    assert(em.out.written().len >= before);
}

/// Records `why` (static text) as the reason the design is not native and
/// returns `error.Unsupported` for the caller to propagate.
pub fn refuse(em: *Emitter, why: []const u8) error{Unsupported} {
    assert(why.len != 0);
    em.why = why;
    return error.Unsupported;
}

/// Whether `xMeaning` and `keepFour` can do anything: callers skip their
/// checks otherwise.
pub fn caresX(em: *const Emitter) bool {
    return em.logic != .four;
}

/// An x or z carries meaning at token `tok`: `--two-state` refuses the
/// design, `auto` keeps it 4-state.
pub fn xMeaning(em: *Emitter, why: []const u8, tok: ?u32) Error!void {
    assert(why.len != 0);
    if (em.logic == .two) return em.refuse(why);
    em.keepFour(why, tok);
}

/// Under `auto`, the design stays 4-state throughout; the first reason is
/// the one kept.
pub fn keepFour(em: *Emitter, why: []const u8, tok: ?u32) void {
    assert(why.len != 0);
    if (em.logic == .auto and em.four == null) em.four = .{ .why = why, .tok = tok };
    if (em.logic != .auto) assert(em.four == null);
}

/// Returns a fresh number for a block label or a capture.
pub fn label(em: *Emitter) u32 {
    assert(em.labels < std.math.maxInt(u32));
    em.labels += 1;
    return em.labels;
}

/// Refuses a real: a `logic.T` holds only integral values.
pub fn fits(em: *Emitter, t: Type) Error!void {
    if (t.real) return em.refuse("a real value");
    assert(!t.real);
}

/// Writes `M.get` (or `M.getw`) of slot `at`'s value. Asserts that the
/// plane layout is laid out and holds `at`.
pub fn get(em: *Emitter, at: u32) Error!void {
    assert(at < em.planes.off.len);
    const w = em.r.values[at].width;
    if (w <= 64) return em.print("M.get(s, {d})", .{em.planes.off[at]});
    try em.print("M.getw(s, {d}, {d})", .{ em.planes.off[at], plane_words.words(w) });
}

/// Returns the slot `e` names in the current scope (`Run.slot`).
pub fn slot(em: *Emitter, e: Ast.ExprId) Error!u32 {
    assert(e != .none);
    const at = em.r.slot(e) catch return em.refuse("a name the engine resolves only at run time");
    assert(at < em.r.values.len);
    return at;
}

/// Returns slot `at`'s width in bits (a real's is 64).
pub fn slotWidth(em: *const Emitter, at: u32) u32 {
    assert(at < em.r.values.len);
    return em.r.values[at].width;
}

/// Returns whether `e` names an element of an unpacked array
/// (`Run.indexedArray`).
pub fn element(em: *Emitter, e: Ast.ExprId) Error!bool {
    assert(e != .none);
    return (em.r.indexedArray(e) catch return em.refuse("an array reference the engine resolves only at run time")) != null;
}

/// Inserts `text` at byte `at` of the text written so far: a declaration a
/// function needs only once its body shows it does. Invalidates every slice
/// of `out` taken before the call.
pub fn insert(em: *Emitter, at: usize, text: []const u8) Error!void {
    const before = em.out.written().len;
    assert(at <= before);
    var list = em.out.toArrayList();
    list.insertSlice(em.arena, at, text) catch return error.OutOfMemory;
    em.out = .fromArrayList(em.arena, &list);
    assert(em.out.written().len == before + text.len);
}
