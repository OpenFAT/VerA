//! The expression table of the AST (LRM §4.2-§4.6, §5.10's event
//! expressions; annex A.8): one SoA row per expression, addressed by `ExprId`,
//! with literal values and variable-arity operand lists in side tables. The
//! parser appends rows; every later stage reads them through `ExprStore`.
//! Elaboration appends to an overlay (`ExprStore.continuing`) whose ids,
//! list offsets and side-table indices continue the parser's, so the
//! parser's rows are never written and keep their numbers.

const std = @import("std");
const Integer = @import("kernels").Integer;
const IntLiteral = @import("lexer.zig").IntLiteral;
const ast = @import("ast.zig");
const ExprId = ast.ExprId;
const StrId = ast.StrId;
const SourceFile = ast.SourceFile;

/// A.8.6 unary_operator, stored in the `extra` column of a `.unary` node:
/// `kernels.fold.UnaryOp`, the operator the value folds take.
pub const UnaryOp = @import("kernels").fold.UnaryOp;

/// A.8.6 binary_operator, stored in the `extra` column of a `.binary` node:
/// `kernels.fold.BinaryOp`.
pub const BinaryOp = @import("kernels").fold.BinaryOp;

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// `.branch_access` `extra` value for A.8.9's hierarchical_unnamed_branch_reference
/// (`V(drv.branch(x, y))`): the child's existing unnamed branch (§5.6.8.2), as
/// against `V(drv.x, drv.y)`, which creates a new one in the writer (§5.6.8.1).
/// The parser rewrites both to the same terminal pair, so this is the only
/// record of which one was written.
pub const branch_ref_hier_unnamed: u32 = 1;

/// Expression node tag: LRM §4.2 (operators), §4.3/§4.5/§4.6 (calls), §4.4
/// (access functions), §5.10 (A.6.5 event expressions).
/// Each arm documents its column usage; `main_tok` is always the token the
/// node is reported at.
pub const ExprTag = enum(u8) {
    // ---- literals and names: §2.6, §2.7, §2.8, A.8.7 ----
    /// `extra` = index into `ExprStore.ints`. LRM §2.6.1.
    int_literal,
    /// Exact four-state or wide constant; rejected by the analog integer boundary.
    logic_literal,
    /// `extra` = index into `ExprStore.reals`. LRM §2.6.2 (incl. SI suffixes).
    real_literal,
    /// `str` = interned, escape-processed contents. LRM §2.7.
    str_literal,
    /// A.2.5 `value_range_expression ::= ... | inf | -inf`. Only legal inside a
    /// `ValueRange`; the finiteness proof reads these directly.
    pos_inf,
    neg_inf,
    /// `str` = name. LRM §2.8 (variables, nets, params, genvars, named events).
    ident,
    /// Dotted name: `extra` = StrId list offset (2+ parts). Covers
    /// hierarchical_identifier (§6.8) and nature_attribute_reference
    /// (§3.6.1.3, e.g. `electrical.potential.abstol`); lowering tells them
    /// apart by resolving the first part.
    hier_ident,

    // ---- operators: §4.2 ----
    /// `lhs` = operand, `extra` = the `UnaryOp`'s `@backingInt`. Read it
    /// with `ExprStore.unOp`.
    unary,
    /// `lhs`, `rhs` operands, `extra` = the `BinaryOp`'s `@backingInt`. Read
    /// it with `ExprStore.binOp`.
    binary,
    /// §4.2.12 `?:`: `lhs` = cond, `rhs` = then, `extra` = the else
    /// operand's `ExprId` as its `@backingInt`. Read the third operand with
    /// `ExprStore.ternaryElse`.
    ternary,

    // ---- calls (all: `str` = callee name, `extra` = ExprId list offset) ----
    /// §4.7 user-defined analog function call (A.8.2 analog_function_call).
    call,
    /// §4.3 math built-in (A.8.2 analog_built_in_function_name). Lowering maps
    /// the name to a MIR op and to the LRM §4.3 domain table.
    builtin_call,
    /// ch9 system function / task-as-expression, and §9.x `analysis("...")`
    /// (A.8.2 analog_system_function_call, analysis_function_call). `$name`
    /// without parens is this tag with an empty arg list.
    sys_call,
    /// §4.5 analog operator / filter: ddt, ddx, idt, idtmod, absdelay,
    /// transition, slew, last_crossing, limexp, laplace_*, zi_* (A.8.2
    /// analog_filter_function_call). Each occurrence owns runtime state, so it
    /// must stay a distinct tag from `builtin_call`.
    filter_call,
    /// §4.6 small-signal / noise: ac_stim, white_noise, flicker_noise,
    /// noise_table, noise_table_log (A.8.2 analog_small_signal_function_call).
    noise_call,

    // ---- access functions: §4.4 ----
    /// §4.4.1 branch probe: `V(a)`, `V(a,b)`, `I(br)`. `str` = access
    /// identifier (`V`/`I`/nature access name, §3.6.1.2), `lhs` = first
    /// net-or-branch reference, `rhs` = second net reference or `.none`.
    /// `extra` = `branch_ref_hier_unnamed` for §5.6.8.2's
    /// `inst.branch(x, y)` spelling, 0 otherwise.
    branch_access,
    /// §4.4.2 / §5.4.3 port branch probe `I(<p>)` (A.8.2
    /// port_probe_function_call). `str` = access identifier, `lhs` = port ref.
    port_access,

    // ---- aggregates: §4.2.13, §3.4.4, A.8.1 ----
    /// `{a, b, ...}`: `extra` = ExprId list offset.
    concat,
    /// `{n{...}}`: `lhs` = repeat count, `rhs` = the inner `.concat`.
    multi_concat,
    /// `'{a, b, ...}` assignment pattern (array param defaults §3.4.4, filter
    /// coefficient args §4.5.4): `extra` = ExprId list offset.
    assign_pattern,
    /// A.8.1's `'{ constant_expression { ... } }` whose count is not a literal
    /// (`'{N{0.5}}`): the parser cannot unroll it before parameters have
    /// values, so the pattern's only element is this node: `lhs` = count,
    /// `rhs` = an `.assign_pattern` holding the group. `Lower.patternElems`
    /// unrolls it with the constant folder.
    pattern_repl,
    /// §3.4.4 array / bit select `base[i]`: `lhs` = base, `rhs` = index.
    index,
    /// `msb:lsb` part select and `analog_range_expression` (A.8.3):
    /// `lhs` = msb, `rhs` = lsb.
    range,
    /// IEEE 1364-2005 §5.2.1 indexed part-select, A.8.3 `base +: width` or
    /// `base -: width`: `lhs` = base, `rhs` = width, `extra` = 0 for `+:` and
    /// 1 for `-:`.
    indexed_range,

    // ---- event expressions: §5.10, A.6.5 ----
    /// `e1 or e2` / `e1, e2`: `lhs`, `rhs`.
    event_or,
    /// `posedge e` / `negedge e`: `lhs` (digital edges, §5.10.1).
    event_posedge,
    event_negedge,
    /// §5.10.2 `initial_step` / `final_step`: `extra` = StrId list offset of
    /// the analysis-name arguments (empty list = no argument list).
    event_initial_step,
    event_final_step,
    /// §5.10.3 monitored event function: cross, above, timer, absdelta (A.6.5
    /// analog_event_functions). `str` = name, `extra` = ExprId list offset
    /// (a `.none` element is an omitted `analog_expression_or_null` argument).
    event_function,
    /// A.6.5 `driver_update expression`: `lhs` is the signal (§9.22.4). A digital
    /// event that §9.22 confines to a connect module, so it belongs under a
    /// `connectmodule`'s `DiscreteBlock`; analog lowering refuses it (E0701).
    event_driver_update,
};

/// One expression row. `ExprStore` keeps these as MultiArrayList columns, so
/// this struct is a row view, never an allocated node.
pub const Node = struct {
    tag: ExprTag,
    /// Token index this node is reported at.
    main_tok: u32 = 0,
    lhs: ExprId = .none,
    rhs: ExprId = .none,
    /// Opcode, literal payload or list offset; see `ExprTag`'s arms.
    extra: u32 = 0,
    /// Interned name, `.none` when the tag carries no name.
    str: StrId = .none,
};

// Budget: 21 bytes a row across the SoA columns (50,875 rows on psp103).
comptime {
    var bytes: usize = 0;
    for (@typeInfo(Node).@"struct".field_types) |T| bytes += @sizeOf(T);
    std.debug.assert(bytes == 21);
}

/// SoA expression store, one row per expression (LRM annex A). `ExprId`
/// indexes every column.
///
/// A store may continue another (`base`, set by `continuing`): the base's
/// rows, list offsets and side-table indices are its first ones and read
/// through it, and its own columns hold only what it appended, numbered
/// after the base's. Every number a row holds is in that one space, so a row
/// copied from the base keeps working. The columns below are this store's
/// own; read rows through the accessors, which route.
pub const ExprStore = struct {
    /// The store this one continues, which it never writes. Null for a
    /// store of its own (every parse).
    base: ?*const ExprStore = null,
    /// Columns: `.tag`, `.main_tok`, `.lhs`, `.rhs`, `.extra`, `.str`.
    nodes: std.MultiArrayList(Node) = .empty,
    /// Shared variable-arity payload pool. Each list is stored as
    /// `[len, e0, e1, ...]`; a row's `extra` is the offset of the `len` word.
    pool: std.ArrayList(u32) = .empty,
    /// Side table for `.real_literal` values (`extra` indexes it). Kept out of
    /// the row so the common integer/ident rows stay narrow.
    reals: std.ArrayList(f64) = .empty,
    /// `.int_literal` values that fit i64, with their source width and sign for
    /// expression sizing.
    ints: std.ArrayList(IntLiteral) = .empty,
    /// `.logic_literal` values: wider or four-state constants. Owns each `planes`.
    logic: std.ArrayList(Integer.Literal) = .empty,

    pub const empty: ExprStore = .{};

    /// Returns an empty store that continues `base` (see `ExprStore`).
    /// `base` must outlive it and must not grow while it lives. Asserts
    /// `base` continues none.
    pub fn continuing(base: *const ExprStore) ExprStore {
        std.debug.assert(base.base == null);
        return .{ .base = base };
    }

    const Column = enum { nodes, pool, reals, ints, logic };

    /// How many entries of `column` the base holds: where this store's own
    /// numbering of it starts.
    fn baseLen(self: *const ExprStore, comptime column: Column) u32 {
        const b = self.base orelse return 0;
        return @intCast(switch (column) {
            .nodes => b.nodes.len,
            .pool => b.pool.items.len,
            .reals => b.reals.items.len,
            .ints => b.ints.items.len,
            .logic => b.logic.items.len,
        });
    }

    /// The store holding row `id`, and the row's index in its own columns.
    fn row(self: *const ExprStore, id: ExprId) struct { *const ExprStore, usize } {
        const i: usize = @backingInt(id);
        const b = self.base orelse return .{ self, i };
        return if (i < b.nodes.len) .{ b, i } else .{ self, i - b.nodes.len };
    }

    /// Returns how many rows the store holds, the base's included: one past
    /// the largest `ExprId`.
    pub fn len(self: *const ExprStore) u32 {
        return self.baseLen(.nodes) + @as(u32, @intCast(self.nodes.len));
    }

    /// Returns how many `pool` words the store holds, the base's included:
    /// one past the largest list offset.
    pub fn poolLen(self: *const ExprStore) u32 {
        return self.baseLen(.pool) + @as(u32, @intCast(self.pool.items.len));
    }

    /// Frees every column and each `logic` literal's `planes`, never the
    /// base's; `gpa` must be the allocator the store was built with.
    pub fn deinit(self: *ExprStore, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
        self.pool.deinit(gpa);
        self.reals.deinit(gpa);
        self.ints.deinit(gpa);
        for (self.logic.items) |literal| gpa.free(literal.planes);
        self.logic.deinit(gpa);
        self.* = .empty;
    }

    /// Appends one row (all columns in lockstep) and returns its handle.
    /// Ids are dense and in append order. On OOM nothing is appended.
    /// Invalidates column slices taken from `nodes`.
    /// Asserts the store holds fewer than `maxInt(u32)` rows (that value is
    /// `ExprId.none`).
    pub fn add(self: *ExprStore, gpa: std.mem.Allocator, node: Node) !ExprId {
        const id: u32 = self.len();
        std.debug.assert(id != @backingInt(ExprId.none));
        try self.nodes.append(gpa, node);
        return @fromBackingInt(@intCast(id));
    }

    /// Appends a row tagged `t` whose `extra` indexes `value` in side table
    /// `column`. On OOM neither table grows.
    fn addSide(self: *ExprStore, gpa: std.mem.Allocator, comptime column: Column, t: ExprTag, main_tok: u32, value: anytype) !ExprId {
        const table = &@field(self, @tagName(column));
        // Room for the value first, then the row: a failure at either step
        // leaves both tables as they were.
        try table.ensureUnusedCapacity(gpa, 1);
        const idx: u32 = self.baseLen(column) + @as(u32, @intCast(table.items.len));
        const id = try self.add(gpa, .{ .tag = t, .main_tok = main_tok, .extra = idx });
        table.appendAssumeCapacity(value);
        return id;
    }

    /// Returns entry `k` of side table `column`, numbered from the base's
    /// first entry (see `ExprStore`).
    fn side(self: *const ExprStore, comptime column: Column, comptime T: type, k: u32) T {
        const o = self.baseLen(column);
        if (k < o) return @field(self.base.?, @tagName(column)).items[k];
        return @field(self, @tagName(column)).items[k - o];
    }

    /// Appends a `.real_literal` row whose value lives in `reals`. On OOM
    /// neither table grows.
    pub fn addReal(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, value: f64) !ExprId {
        return self.addSide(gpa, .reals, .real_literal, main_tok, value);
    }

    /// Appends a synthetic unsized, signed `.int_literal` (the implementation
    /// integer width).
    pub fn addInt(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, value: i64) !ExprId {
        return self.addIntLiteral(gpa, main_tok, .{ .value = value, .width = 0, .signed = true });
    }

    /// Appends an `.int_literal` row whose value lives in `ints`, keeping its
    /// width, sign and radix. On OOM neither table grows.
    pub fn addIntLiteral(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, literal: IntLiteral) !ExprId {
        return self.addSide(gpa, .ints, .int_literal, main_tok, literal);
    }

    /// Appends a `.logic_literal` row. On success the store owns
    /// `literal.planes`, which must be allocated with `gpa`; `deinit` frees
    /// it. On OOM nothing is stored and the planes stay the caller's.
    pub fn addLogic(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, literal: Integer.Literal) !ExprId {
        return self.addSide(gpa, .logic, .logic_literal, main_tok, literal);
    }

    /// Returns a `.logic_literal`'s value; asserts the tag. `planes` stays owned
    /// by the store.
    pub fn logicValue(self: *const ExprStore, id: ExprId) Integer.Literal {
        std.debug.assert(self.tag(id) == .logic_literal);
        return self.side(.logic, Integer.Literal, self.extraOf(id));
    }

    /// Returns every column of row `id`. A walk that needs one field reads
    /// that column instead (`tag`, `lhs`, ...). `id` must not be `.none`;
    /// the column accessors below share that precondition.
    pub fn get(self: *const ExprStore, id: ExprId) Node {
        const s, const i = self.row(id);
        return s.nodes.get(i);
    }

    /// Returns row `id`'s `ExprTag`, which says what its other columns hold.
    pub fn tag(self: *const ExprStore, id: ExprId) ExprTag {
        const s, const i = self.row(id);
        return s.nodes.items(.tag)[i];
    }
    /// Returns the token index row `id` is reported at.
    pub fn mainTok(self: *const ExprStore, id: ExprId) u32 {
        const s, const i = self.row(id);
        return s.nodes.items(.main_tok)[i];
    }
    /// Returns row `id`'s first operand, `.none` when its tag has none.
    pub fn lhs(self: *const ExprStore, id: ExprId) ExprId {
        const s, const i = self.row(id);
        return s.nodes.items(.lhs)[i];
    }
    /// Returns row `id`'s second operand, `.none` when its tag has none.
    pub fn rhs(self: *const ExprStore, id: ExprId) ExprId {
        const s, const i = self.row(id);
        return s.nodes.items(.rhs)[i];
    }
    /// Returns row `id`'s `extra` word: an opcode, a side-table index or a
    /// `pool` offset, as its `ExprTag` arm says.
    pub fn extraOf(self: *const ExprStore, id: ExprId) u32 {
        const s, const i = self.row(id);
        return s.nodes.items(.extra)[i];
    }
    /// Returns row `id`'s interned name, `.none` when its tag carries none.
    pub fn strOf(self: *const ExprStore, id: ExprId) StrId {
        const s, const i = self.row(id);
        return s.nodes.items(.str)[i];
    }

    /// Returns a `.unary` node's operator; asserts the tag.
    pub fn unOp(self: *const ExprStore, id: ExprId) UnaryOp {
        std.debug.assert(self.tag(id) == .unary);
        return @fromBackingInt(@intCast(@as(u8, @intCast(self.extraOf(id)))));
    }
    /// Returns a `.binary` node's operator; asserts the tag.
    pub fn binOp(self: *const ExprStore, id: ExprId) BinaryOp {
        std.debug.assert(self.tag(id) == .binary);
        return @fromBackingInt(@intCast(@as(u8, @intCast(self.extraOf(id)))));
    }
    /// Returns the third operand of a §4.2.12 `?:`; asserts the tag.
    pub fn ternaryElse(self: *const ExprStore, id: ExprId) ExprId {
        std.debug.assert(self.tag(id) == .ternary);
        return @fromBackingInt(@intCast(self.extraOf(id)));
    }
    /// Returns a §2.6.1 `.int_literal`'s value; asserts the tag.
    pub fn intValue(self: *const ExprStore, id: ExprId) i64 {
        std.debug.assert(self.tag(id) == .int_literal);
        return self.intLiteral(id).value;
    }
    /// Returns a `.int_literal` with its width and sign; asserts the tag.
    pub fn intLiteral(self: *const ExprStore, id: ExprId) IntLiteral {
        std.debug.assert(self.tag(id) == .int_literal);
        return self.side(.ints, IntLiteral, self.extraOf(id));
    }
    /// Returns a §2.6.2 `.real_literal`'s value; asserts the tag.
    pub fn realValue(self: *const ExprStore, id: ExprId) f64 {
        std.debug.assert(self.tag(id) == .real_literal);
        return self.side(.reals, f64, self.extraOf(id));
    }

    /// Stores a variable-arity list; returns the offset to put in a row's
    /// `extra`. Invalidates slices returned by `list`, `args` and `nameParts`.
    fn addList(self: *ExprStore, gpa: std.mem.Allocator, items: []const u32) !u32 {
        const off: u32 = self.poolLen();
        try self.pool.ensureUnusedCapacity(gpa, items.len + 1);
        self.pool.appendAssumeCapacity(@intCast(items.len));
        self.pool.appendSliceAssumeCapacity(items);
        return off;
    }
    /// Stores an ExprId list; returns its pool offset.
    pub fn addExprList(self: *ExprStore, gpa: std.mem.Allocator, items: []const ExprId) !u32 {
        return self.addList(gpa, @ptrCast(items));
    }
    /// Stores a StrId list; returns its pool offset.
    pub fn addStrList(self: *ExprStore, gpa: std.mem.Allocator, items: []const StrId) !u32 {
        return self.addList(gpa, @ptrCast(items));
    }

    /// Returns the list stored at pool offset `off`, which must be an offset
    /// `addExprList` or `addStrList` returned. The slice is invalidated by the
    /// next list append.
    pub fn list(self: *const ExprStore, off: u32) []const u32 {
        const o = self.baseLen(.pool);
        const pool = if (off < o) self.base.?.pool.items else self.pool.items;
        const at = if (off < o) off else off - o;
        const n = pool[at];
        return pool[at + 1 ..][0..n];
    }

    /// Returns the arguments of any call-shaped tag (`call`, `builtin_call`,
    /// `sys_call`, `filter_call`, `noise_call`, `event_function`) or the
    /// elements of a `concat` / `assign_pattern`. Same lifetime as `list`.
    pub fn args(self: *const ExprStore, id: ExprId) []const ExprId {
        return @ptrCast(self.list(self.extraOf(id)));
    }
    /// Returns the parts of a `.hier_ident`, or the analysis names of an
    /// `.event_initial_step` / `.event_final_step`. Same lifetime as `list`.
    pub fn nameParts(self: *const ExprStore, id: ExprId) []const StrId {
        return @ptrCast(self.list(self.extraOf(id)));
    }

    /// Returns every child expression of `id`, in source order. This is the one
    /// exhaustive statement of `ExprTag`'s column usage, so a new tag is a
    /// compile error here. Elements may be `.none` (an omitted argument, a
    /// one-terminal probe). A list tag returns its pool slice; otherwise the
    /// result points into `buf`.
    pub fn children(self: *const ExprStore, id: ExprId, buf: *[3]ExprId) []const ExprId {
        switch (self.tag(id)) {
            .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident => return &.{},
            // StrId lists, not expressions.
            .hier_ident, .event_initial_step, .event_final_step => return &.{},
            .unary, .event_posedge, .event_negedge, .event_driver_update, .port_access => {
                buf[0] = self.lhs(id);
                return buf[0..1];
            },
            .binary, .index, .range, .indexed_range, .multi_concat, .pattern_repl, .event_or, .branch_access => {
                buf[0..2].* = .{ self.lhs(id), self.rhs(id) };
                return buf[0..2];
            },
            .ternary => {
                buf.* = .{ self.lhs(id), self.rhs(id), self.ternaryElse(id) };
                return buf;
            },
            .call, .builtin_call, .sys_call, .filter_call, .noise_call, .event_function, .concat, .assign_pattern => return self.args(id),
        }
    }
};

// ponytail: not modelled, because nothing would produce or consume the tag:
//   · `min:typ:max` (A.8.3 mintypmax_expression); the parser keeps the typ
//     value. Add a `.mintypmax` tag if a fixture needs the triple.

test "ExprStore round-trips rows, lists and literals" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    const v = try f.intern(gpa, "V");
    const a = try f.intern(gpa, "a");
    try std.testing.expectEqual(v, try f.intern(gpa, "V")); // idempotent
    try std.testing.expectEqualStrings("a", f.str(a));

    const one = try f.exprs.addInt(gpa, 0, 1);
    const two_pt_5 = try f.exprs.addReal(gpa, 1, 2.5);
    try std.testing.expectEqual(@as(i32, 1), f.exprs.intValue(one));
    try std.testing.expectEqual(@as(f64, 2.5), f.exprs.realValue(two_pt_5));

    const sum = try f.exprs.add(gpa, .{
        .tag = .binary,
        .main_tok = 2,
        .lhs = one,
        .rhs = two_pt_5,
        .extra = @backingInt(BinaryOp.add),
    });
    try std.testing.expectEqual(BinaryOp.add, f.exprs.binOp(sum));
    try std.testing.expectEqual(one, f.exprs.lhs(sum));

    // `V(a)`: §4.4.1 branch access.
    const node_a = try f.exprs.add(gpa, .{ .tag = .ident, .main_tok = 3, .str = a });
    const probe = try f.exprs.add(gpa, .{ .tag = .branch_access, .main_tok = 4, .lhs = node_a, .str = v });
    try std.testing.expectEqual(ExprId.none, f.exprs.rhs(probe));

    // §4.3 call with an argument list in the shared pool.
    const off = try f.exprs.addExprList(gpa, &.{ sum, probe });
    const call = try f.exprs.add(gpa, .{ .tag = .builtin_call, .main_tok = 5, .extra = off, .str = try f.intern(gpa, "pow") });
    try std.testing.expectEqualSlices(ExprId, &.{ sum, probe }, f.exprs.args(call));

    // §4.2.12 ternary keeps its third operand in `extra`.
    const t = try f.exprs.add(gpa, .{ .tag = .ternary, .lhs = probe, .rhs = one, .extra = @backingInt(two_pt_5) });
    try std.testing.expectEqual(two_pt_5, f.exprs.ternaryElse(t));
}

test "children: every tag's operands, in source order" {
    const gpa = std.testing.allocator;
    var s: ExprStore = .empty;
    defer s.deinit(gpa);
    const a = try s.addInt(gpa, 0, 1);
    const b = try s.addInt(gpa, 0, 2);
    const c = try s.addInt(gpa, 0, 3);
    const one = [_]ExprId{a};
    const two = [_]ExprId{ a, b };
    const three = [_]ExprId{ a, b, c };
    // A list may hold `.none` (an omitted argument) and keeps its order.
    const listed = [_]ExprId{ c, .none, a };
    const name: StrId = @fromBackingInt(7);
    const list_off = try s.addExprList(gpa, &listed);
    const names_off = try s.addStrList(gpa, &.{name});
    var buf: [3]ExprId = undefined;
    const Case = struct { node: Node, want: []const ExprId };
    for (std.enums.values(ExprTag)) |t| {
        // The oracle is this table, written from `ExprTag`'s arm comments.
        const case: Case = switch (t) {
            .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident => .{ .node = .{ .tag = t, .lhs = a, .rhs = b }, .want = &.{} },
            .hier_ident, .event_initial_step, .event_final_step => .{ .node = .{ .tag = t, .extra = names_off }, .want = &.{} },
            .unary, .event_posedge, .event_negedge, .event_driver_update, .port_access => .{ .node = .{ .tag = t, .lhs = a, .rhs = b }, .want = &one },
            .binary, .index, .range, .indexed_range, .multi_concat, .pattern_repl, .event_or, .branch_access => .{ .node = .{ .tag = t, .lhs = a, .rhs = b }, .want = &two },
            .ternary => .{ .node = .{ .tag = t, .lhs = a, .rhs = b, .extra = @backingInt(c) }, .want = &three },
            .call, .builtin_call, .sys_call, .filter_call, .noise_call, .event_function, .concat, .assign_pattern => .{ .node = .{ .tag = t, .extra = list_off }, .want = &listed },
        };
        const id = try s.add(gpa, case.node);
        try std.testing.expectEqualSlices(ExprId, case.want, s.children(id, &buf));
    }
    try std.testing.expectEqualSlices(StrId, &.{name}, s.nameParts(try s.add(gpa, .{ .tag = .hier_ident, .extra = names_off })));
}

test "unOp/binOp read back every operator" {
    const gpa = std.testing.allocator;
    var s: ExprStore = .empty;
    defer s.deinit(gpa);
    for (std.enums.values(UnaryOp)) |op| {
        const id = try s.add(gpa, .{ .tag = .unary, .extra = @backingInt(op) });
        try std.testing.expectEqual(op, s.unOp(id));
    }
    for (std.enums.values(BinaryOp)) |op| {
        const id = try s.add(gpa, .{ .tag = .binary, .extra = @backingInt(op) });
        try std.testing.expectEqual(op, s.binOp(id));
    }
}

test "literal side tables keep width, sign, radix and every f64 bit; an empty list is empty" {
    const gpa = std.testing.allocator;
    var s: ExprStore = .empty;
    defer s.deinit(gpa);
    // `-8'sh6`'s operand as the parser stores it: 8 bits, signed, radix 16.
    const want: IntLiteral = .{ .value = 6, .width = 8, .signed = true, .radix = 16 };
    const lit = try s.addIntLiteral(gpa, 3, want);
    try std.testing.expectEqual(want, s.intLiteral(lit));
    try std.testing.expectEqual(@as(u32, 3), s.mainTok(lit));
    try std.testing.expectEqual(ExprTag.int_literal, s.tag(lit));
    // `addInt` is the unsized, signed, decimal form.
    const synth = try s.addInt(gpa, 0, -1);
    try std.testing.expectEqual(IntLiteral{ .value = -1, .width = 0, .signed = true, .radix = 10 }, s.intLiteral(synth));
    const nan = try s.addReal(gpa, 0, std.math.nan(f64));
    try std.testing.expect(std.math.isNan(s.realValue(nan)));
    const neg_zero = try s.addReal(gpa, 0, -0.0);
    try std.testing.expect(std.math.signbit(s.realValue(neg_zero)));
    try std.testing.expectEqual(@as(usize, 0), s.list(try s.addExprList(gpa, &.{})).len);
    // Lists share one pool; each offset reads back its own.
    const l1 = try s.addExprList(gpa, &.{lit});
    const l2 = try s.addExprList(gpa, &.{ synth, nan });
    try std.testing.expectEqual(@as(usize, 1), s.list(l1).len);
    try std.testing.expectEqual(@as(usize, 2), s.list(l2).len);
}

/// The appends `continuing` is tested with: `n` = 0 writes the parser's
/// half, 1 the overlay's, which copies a base row and a base list offset.
fn appendHalf(s: *ExprStore, gpa: std.mem.Allocator, n: u32, prev: []const ExprId) ![4]ExprId {
    const int = try s.addIntLiteral(gpa, n, .{ .value = 6 + n, .width = 8, .signed = true, .radix = 16 });
    const real = try s.addReal(gpa, n, 0.5 + @as(f64, @floatFromInt(n)));
    const planes = try gpa.alloc(u64, 2);
    @memset(planes, n);
    const logic = try s.addLogic(gpa, n, .{ .width = 64, .sized = true, .signed = false, .planes = planes });
    const items: []const ExprId = if (n == 0) &.{ int, real } else &.{ prev[0], int, logic };
    const call = try s.add(gpa, .{ .tag = .call, .main_tok = n, .extra = try s.addExprList(gpa, items) });
    return .{ int, real, logic, call };
}

test "continuing: a store's ids, offsets and side indices continue the base's, which never grows" {
    const gpa = std.testing.allocator;
    var base: ExprStore = .empty;
    defer base.deinit(gpa);
    const b = try appendHalf(&base, gpa, 0, &.{});
    var over: ExprStore = .continuing(&base);
    defer over.deinit(gpa);
    const o = try appendHalf(&over, gpa, 1, &b);
    // A copy of a base row: its `extra` is a base list offset.
    const copied = try over.add(gpa, base.get(b[3]));
    // The oracle: one store doing the same appends in the same order.
    var one: ExprStore = .empty;
    defer one.deinit(gpa);
    const ob = try appendHalf(&one, gpa, 0, &.{});
    const oo = try appendHalf(&one, gpa, 1, &ob);
    try std.testing.expectEqualSlices(ExprId, &ob, &b);
    try std.testing.expectEqualSlices(ExprId, &oo, &o);
    try std.testing.expectEqual(try one.add(gpa, one.get(ob[3])), copied);
    try std.testing.expectEqual(one.len(), over.len());
    try std.testing.expectEqual(one.poolLen(), over.poolLen());
    for (0..one.len()) |i| {
        const id: ExprId = @fromBackingInt(@intCast(i));
        try std.testing.expectEqual(one.get(id), over.get(id));
        var bo: [3]ExprId = undefined;
        var bv: [3]ExprId = undefined;
        try std.testing.expectEqualSlices(ExprId, one.children(id, &bo), over.children(id, &bv));
        const t = one.tag(id);
        if (t == .int_literal) try std.testing.expectEqual(one.intLiteral(id), over.intLiteral(id));
        if (t == .real_literal) try std.testing.expectEqual(one.realValue(id), over.realValue(id));
        if (t == .logic_literal) try std.testing.expectEqualSlices(u64, one.logicValue(id).planes, over.logicValue(id).planes);
    }
    try std.testing.expectEqual(@as(u32, 4), base.len());
    try std.testing.expectEqual(@as(usize, 1), base.logic.items.len);
}

/// Allocates planes and hands them to `addLogic`; frees them itself only
/// when `addLogic` stored nothing, which is its documented contract.
fn addPlanes(s: *ExprStore, gpa: std.mem.Allocator, tok: u32) !ExprId {
    const planes = try gpa.alloc(u64, 2);
    @memset(planes, 0);
    errdefer gpa.free(planes);
    return s.addLogic(gpa, tok, .{ .width = 64, .sized = true, .signed = false, .planes = planes });
}

fn addLiteralsOom(gpa: std.mem.Allocator) !void {
    var s: ExprStore = .empty;
    defer s.deinit(gpa);
    for (0..12) |i| {
        const before = [4]usize{ s.nodes.len, s.ints.items.len, s.reals.items.len, s.logic.items.len };
        const tok: u32 = @intCast(i);
        const added = switch (i % 3) {
            0 => s.addInt(gpa, tok, 1),
            1 => s.addReal(gpa, tok, 0.5),
            else => addPlanes(&s, gpa, tok),
        };
        _ = added catch |err| {
            // No row without its value, and no value without its row.
            const after = [4]usize{ s.nodes.len, s.ints.items.len, s.reals.items.len, s.logic.items.len };
            try std.testing.expectEqualSlices(usize, &before, &after);
            return err;
        };
    }
}

test "the literal adders store nothing on OOM, so the planes stay the caller's" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addLiteralsOom, .{});
}

fn addLogicOnce(gpa: std.mem.Allocator) !void {
    var s: ExprStore = .empty;
    defer s.deinit(gpa);
    _ = try addPlanes(&s, gpa, 0);
}

test "deinit frees each logic literal's planes" {
    try addLogicOnce(std.testing.allocator);
}
