//! The AST the parser builds from the token stream (LRM annex A, ch3 declarations).
//! In: rows the parser appends. Out: `SourceFile`, read by elaboration,
//! lowering, the digital engine and VPI. Clauses: §1 source_text, §2.7,
//! §2.8, §2.9, ch5's statement pool; the row types cite their own.
//! Expressions are SoA rows addressed by `ExprId`, statements a flat pool addressed
//! by `StmtId`, names interned as `StrId`; variable-arity payloads share one `u32`
//! pool. Every store is append-only, so the same tokens give the same ids. Lists are
//! unmanaged and meant for the compilation arena; `deinit` exists so tests can use a
//! gpa. Interned slices are borrowed and must outlive the `SourceFile`.
//!
//! This file holds the handles and `SourceFile`, the root that owns every
//! store; the string table is `base`'s (interner.zig). The row types live by
//! table: expressions in ast_expr.zig, declarations in ast_decl.zig, statements and their walks in
//! ast_stmt.zig; the aliases below are their API.

const std = @import("std");
const expr_file = @import("ast_expr.zig");
const decl_file = @import("ast_decl.zig");
const stmt_file = @import("ast_stmt.zig");

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

/// Handle into the expression columns (LRM annex A expression grammar),
/// `base`'s.
pub const ExprId = @import("base").ExprId;
/// Handle into the statement pool. LRM §5 behavioral statements.
pub const StmtId = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle into the string intern table. LRM §2.8 identifiers, §2.7 strings.
pub const StrId = @import("base").StrId;
/// The §2.7/§2.8 intern table (`base`'s), kept here as the AST's own name.
pub const StringInterner = @import("base").StringInterner;

/// Scalar data types. LRM §3.1, §3.2, §3.3, §3.4.1 (`base`'s, which
/// documents the variants).
pub const Type = @import("base").Type;

/// Port / function-argument direction. LRM §6.5.2.2 (ports), §4.7.2.3
/// (`base`'s, which documents the variants).
pub const Direction = @import("base").Direction;

/// LRM §3.6.1 / A.1.7 `potential_or_flow`.
pub const PotentialOrFlow = enum(u8) { potential, flow };

// Expressions: LRM §4.2-§4.6, A.8 (ast_expr.zig).
pub const UnaryOp = expr_file.UnaryOp;
pub const BinaryOp = expr_file.BinaryOp;
pub const branch_ref_hier_unnamed = expr_file.branch_ref_hier_unnamed;
pub const ExprTag = expr_file.ExprTag;
pub const Node = expr_file.Node;
pub const ExprStore = expr_file.ExprStore;

// Declarations: LRM ch3, §4.7, ch6, §7.7, A.5, IEEE 1364-2005 §13.3 (ast_decl.zig).
pub const Dim = decl_file.Dim;
pub const ValueRange = decl_file.ValueRange;
pub const ParamDecl = decl_file.ParamDecl;
pub const AliasParam = decl_file.AliasParam;
pub const VarDecl = decl_file.VarDecl;
pub const NetKind = decl_file.NetKind;
pub const Strength = decl_file.Strength;
pub const NetStrength = decl_file.NetStrength;
pub const Delay3 = decl_file.Delay3;
pub const NetDecl = decl_file.NetDecl;
pub const BranchDecl = decl_file.BranchDecl;
pub const Port = decl_file.Port;
pub const FuncArg = decl_file.FuncArg;
pub const Subroutine = decl_file.Subroutine;
pub const EventDecl = decl_file.EventDecl;
pub const TfPort = decl_file.TfPort;
pub const FuncDecl = decl_file.FuncDecl;
pub const AnalogBlock = decl_file.AnalogBlock;
pub const DiscreteBlock = decl_file.DiscreteBlock;
pub const ContAssign = decl_file.ContAssign;
pub const GateKind = decl_file.GateKind;
pub const GateInst = decl_file.GateInst;
pub const SpecEdge = decl_file.SpecEdge;
pub const SpecPolarity = decl_file.SpecPolarity;
pub const SpecPath = decl_file.SpecPath;
pub const TimingCheck = decl_file.TimingCheck;
pub const PullInst = decl_file.PullInst;
pub const SwitchKind = decl_file.SwitchKind;
pub const SwitchInst = decl_file.SwitchInst;
pub const PrimTerm = decl_file.PrimTerm;
pub const primTerms = decl_file.primTerms;
pub const setPrimTerm = decl_file.setPrimTerm;
pub const PortConn = decl_file.PortConn;
pub const ParamOverride = decl_file.ParamOverride;
pub const Defparam = decl_file.Defparam;
pub const Instance = decl_file.Instance;
pub const ModuleDecl = decl_file.ModuleDecl;
pub const LteAttr = decl_file.LteAttr;
pub const NatureAttr = decl_file.NatureAttr;
pub const AttributeOwner = decl_file.AttributeOwner;
pub const AttributeBinding = decl_file.AttributeBinding;
pub const NatureDecl = decl_file.NatureDecl;
pub const DisciplineDecl = decl_file.DisciplineDecl;
pub const ParamsetDecl = decl_file.ParamsetDecl;
pub const ParamsetOverride = decl_file.ParamsetOverride;
pub const ConnectRulesDecl = decl_file.ConnectRulesDecl;
pub const ConnectInsertion = decl_file.ConnectInsertion;
pub const ConnectResolution = decl_file.ConnectResolution;
pub const UdpRow = decl_file.UdpRow;
pub const UdpDecl = decl_file.UdpDecl;
pub const LibCell = decl_file.LibCell;
pub const ConfigRule = decl_file.ConfigRule;
pub const ConfigDecl = decl_file.ConfigDecl;

// Statements: LRM ch5, A.6 (ast_stmt.zig).
pub const Stmt = stmt_file.Stmt;
pub const StmtRow = stmt_file.StmtRow;
pub const ProcContinuous = stmt_file.ProcContinuous;
pub const CaseKind = stmt_file.CaseKind;
pub const CaseArm = stmt_file.CaseArm;
pub const GenItems = stmt_file.GenItems;
pub const SeqBlock = stmt_file.SeqBlock;

// ---------------------------------------------------------------------------
// Source file: LRM §1 source_text, A.1.2
// ---------------------------------------------------------------------------

/// Root of one parsed file (LRM §1 source_text, annex A). Arena-owned; the
/// decl slices are never freed by `deinit`.
///
/// Elaboration never writes a parse: it writes an `overlay`, a file that
/// continues the parse. The overlay's interner,
/// expressions and statements number on from the parse's, so every id keeps
/// its number and reads the same through the overlay; its decl slices start
/// as the parse's and elaboration may replace them.
pub const SourceFile = struct {
    /// The parse this file is an overlay of, which it never writes; null for
    /// a parse. Set only by `overlay`.
    base: ?*const SourceFile = null,
    /// §2.8 interned identifiers and §2.7 strings.
    strings: StringInterner = .empty,
    /// annex A expression grammar, SoA.
    exprs: ExprStore = .empty,
    /// §5 statement pool: this file's own rows, after the base's. A StmtId
    /// minus the base's count indexes it. Read through `stmt`.
    stmts: std.ArrayList(StmtRow) = .empty,
    /// The `SeqBlock` of every `.block` row, in statement order; a row's
    /// `BlockId`, minus the base's count, indexes it.
    blocks: std.ArrayList(SeqBlock) = .empty,
    /// Token index per statement, parallel to `stmts`, kept apart so `Stmt`
    /// stays a pure union.
    stmt_toks: std.ArrayList(u32) = .empty,

    // Top-level declarations, in source order (A.1.2 description).
    modules: []const ModuleDecl = &.{}, // §6.2
    disciplines: []const DisciplineDecl = &.{}, // §3.6.2
    natures: []const NatureDecl = &.{}, // §3.6.1
    paramsets: []const ParamsetDecl = &.{}, // §6.4
    connectrules: []const ConnectRulesDecl = &.{}, // §7.7
    udps: []const UdpDecl = &.{}, // §8.5.3 / A.5.1
    configs: []const ConfigDecl = &.{}, // IEEE 1364-2005 §13.3

    /// How many leading entries of `modules` are the annex E prelude (Table E.1
    /// SPICE primitives, prepended as source by `Preprocessor.spice_primitives`)
    /// rather than the user's declarations. E.3.3 prefers a user module of the
    /// same name, so lookups search `userModules()` first; and §6.2.2's top must
    /// be a module the user wrote. Zero with `--no-std-defs`; set by the caller,
    /// not the parser, because it is a property of the compilation.
    builtin_modules: u32 = 0,
    /// How many leading entries of `natures` are annex D.1's, preloaded with
    /// the prelude. Zero with `--no-std-defs`; set by the caller.
    builtin_natures: u32 = 0,
    /// The source `include`d annex D.1 itself (`Preprocessor.Output.annex_d_included`),
    /// so the `builtin_natures` take part in §3.13.2's uniqueness rule
    /// (specification/Vague_Decisions.md VD-096). Set by the caller.
    annex_d_included: bool = false,
    /// How many leading entries of `disciplines` (the prelude's annex D.1
    /// ones) the source may not name, because it did not include
    /// `disciplines.vams` under `require_std_includes`. Set by the caller.
    hidden_disciplines: u32 = 0,

    /// How many of the last `builtin_modules` entries were synthesized from
    /// SPICE `.MODEL`/`.SUBCKT` cards (`spice_cards.synthesize`) rather than
    /// transcribed from Table E.1. E.2.1's case-insensitive match applies only
    /// to netlist names, so `elaborate.findModule` must not reach Table E.1's
    /// rows; and E.3.2's access-function substitution is for "analog
    /// primitives", which a netlist wrapper is not.
    netlist_modules: u32 = 0,
    /// E.1.2 bullet 2: the netlist's `.MODEL` cards whose type names a
    /// primitive VerA does not support, as lower-case `name type`. They
    /// declare no module; elaboration refuses an instance of one (E0952).
    netlist_unsupported: []const []const u8 = &.{},

    /// VerA's vendor attributes, `vera_lte`, `vera_interp`, `vera_nodiff` and
    /// `vera_timepoint` (§2.9 `attribute_instance`), where one decorates an analog statement
    /// (A.6.4) or suffixes an operator call's name (A.8.2 gives that slot only
    /// to `analog_function_call`; VerA extends it). All attributes also keep
    /// their parsed owners below and remain in `ModuleDecl.attrs` for
    /// constant-expression validation. `vera_lte` decides which
    /// §5.6.1.2 charge sites join the host's truncation-error check
    /// (`contract.QStamp`); `vera_interp` which `absdelay` sites interpolate
    /// quadratically; `vera_nodiff` which assignments store no derivative;
    /// `vera_timepoint` which statements run once per timepoint.
    /// Few enough that a list beats a map.
    lte_attrs: std.ArrayList(LteAttr) = .empty,
    /// Every source attribute, including vendor attributes, with its owner.
    attributes: std.ArrayList(AttributeBinding) = .empty,
    /// IEEE 1364-2005 §12.4.1 hierarchical names whose instance select does
    /// not fold at parse time (`target[i].val`, `i` a genvar). See `HierIndex`.
    hier_indices: std.ArrayList(HierIndex) = .empty,

    /// One `.hier_ident` (or hierarchical `.call`) with unfolded instance
    /// selects. Each such segment is spelled `name[]` in the expression's
    /// parts (`target[].val`), where a folded one is `name[k]`; `indices`
    /// holds the unfolded index expressions in segment order, for
    /// elaboration to fold and respell. `tok` is the expression's main token.
    /// A digital parse only, as `Defparam.indices`.
    pub const HierIndex = struct { tok: u32, indices: []const ExprId };

    /// Returns the unfolded instance-select indices of the hierarchical name
    /// whose main token is `tok`, in segment order; empty when every select
    /// folded. Linear in `hier_indices`, which only genvar-indexed names fill.
    pub fn hierIndices(self: *const SourceFile, tok: u32) []const ExprId {
        for (self.hier_indices.items) |h| if (h.tok == tok) return h.indices;
        return &.{};
    }

    /// Returns the `kind` attribute on statement `id`, if any; the last one
    /// wins (§2.9). Linear in `lte_attrs`.
    pub fn stmtLte(self: *const SourceFile, id: StmtId, kind: @FieldType(LteAttr, "kind")) ?LteAttr {
        var out: ?LteAttr = null;
        for (self.lte_attrs.items) |a| if (a.stmt == id and a.kind == kind) {
            out = a;
        };
        return out;
    }

    /// Returns the `kind` attribute suffixed to call `id`'s name, if any.
    pub fn exprLte(self: *const SourceFile, id: ExprId, kind: @FieldType(LteAttr, "kind")) ?LteAttr {
        var out: ?LteAttr = null;
        for (self.lte_attrs.items) |a| if (a.expr == id and a.kind == kind) {
            out = a;
        };
        return out;
    }

    /// Returns `modules` minus the annex E prelude. See `builtin_modules`.
    pub fn userModules(self: *const SourceFile) []const ModuleDecl {
        return self.modules[@min(self.builtin_modules, self.modules.len)..];
    }

    /// Returns the Table E.1 rows: the prelude minus its netlist-derived tail.
    pub fn tablePrimitives(self: *const SourceFile) []const ModuleDecl {
        const end = @min(self.builtin_modules, self.modules.len);
        return self.modules[0 .. end - @min(self.netlist_modules, end)];
    }

    /// Returns the modules a SPICE netlist contributed. See `netlist_modules`.
    pub fn netlistModules(self: *const SourceFile) []const ModuleDecl {
        const end = @min(self.builtin_modules, self.modules.len);
        return self.modules[end - @min(self.netlist_modules, end) .. end];
    }

    pub const empty: SourceFile = .{};

    /// What the caller, not the parser, knows about the compilation: the
    /// fields of the same names, which `overlay` sets.
    pub const Compilation = struct {
        builtin_modules: u32 = 0,
        builtin_natures: u32 = 0,
        annex_d_included: bool = false,
        hidden_disciplines: u32 = 0,
        netlist_modules: u32 = 0,
        netlist_unsupported: []const []const u8 = &.{},
    };

    /// Returns an overlay of `base` (see `SourceFile`), with the caller-set
    /// fields from `c`. Its interner, expressions and statements continue
    /// `base`'s; the decl slices, `attributes` and `lte_attrs` are borrowed
    /// from `base` (never appended to). `base` must outlive the overlay and
    /// must not change while it lives. Asserts `base` is a parse.
    pub fn overlay(base: *const SourceFile, c: Compilation) SourceFile {
        std.debug.assert(base.base == null);
        return .{
            .base = base,
            .strings = .continuing(&base.strings),
            .exprs = .continuing(&base.exprs),
            .modules = base.modules,
            .disciplines = base.disciplines,
            .natures = base.natures,
            .paramsets = base.paramsets,
            .connectrules = base.connectrules,
            .udps = base.udps,
            .configs = base.configs,
            .builtin_modules = c.builtin_modules,
            .builtin_natures = c.builtin_natures,
            .annex_d_included = c.annex_d_included,
            .hidden_disciplines = c.hidden_disciplines,
            .netlist_modules = c.netlist_modules,
            .netlist_unsupported = c.netlist_unsupported,
            .lte_attrs = base.lte_attrs,
            .attributes = base.attributes,
            .hier_indices = base.hier_indices,
        };
    }

    /// The base's statement and block counts: where this file's own start.
    fn baseStmts(self: *const SourceFile) u32 {
        const b = self.base orelse return 0;
        return @intCast(b.stmts.items.len);
    }
    fn baseBlocks(self: *const SourceFile) u32 {
        const b = self.base orelse return 0;
        return @intCast(b.blocks.items.len);
    }

    /// Frees the append-only stores (strings, expressions, statements, blocks,
    /// the token column, `attributes` and `lte_attrs`) so an AST built on a
    /// gpa is leak-free; an overlay frees only its own, never the base's or
    /// the borrowed `attributes` and `lte_attrs`. The decl slices are not
    /// freed; they belong to the arena or caller.
    pub fn deinit(self: *SourceFile, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.exprs.deinit(gpa);
        self.stmts.deinit(gpa);
        self.blocks.deinit(gpa);
        self.stmt_toks.deinit(gpa);
        if (self.base == null) {
            self.attributes.deinit(gpa);
            self.lte_attrs.deinit(gpa);
            self.hier_indices.deinit(gpa);
        }
        self.* = .empty;
    }

    /// Starts this file from `src`, a parse of a prefix of its source (see
    /// `parser.Seed`). Asserts `self` is empty.
    ///
    /// The strings, expressions, statements, `attributes` and `lte_attrs` are
    /// copied with `gpa`, because later stages append to them; ids stay valid
    /// since every column is append-only. The module, discipline, nature,
    /// paramset, connectrules, UDP and config slices are borrowed: no later
    /// stage writes a decl, so `src` must outlive `self`. The caller-set
    /// counts (`builtin_modules` and the rest) are not copied.
    /// On OOM `self` holds a partial copy that `deinit(gpa)` frees.
    /// Asserts `src` is a parse, not an overlay.
    pub fn seedFrom(self: *SourceFile, gpa: std.mem.Allocator, src: *const SourceFile) !void {
        std.debug.assert(src.base == null and self.base == null);
        std.debug.assert(self.strings.strings.items.len == 0);
        std.debug.assert(self.exprs.nodes.len == 0);
        std.debug.assert(self.stmts.items.len == 0);
        self.strings = try src.strings.clone(gpa);
        self.exprs.nodes = try src.exprs.nodes.clone(gpa);
        self.exprs.pool = try src.exprs.pool.clone(gpa);
        self.exprs.reals = try src.exprs.reals.clone(gpa);
        self.exprs.ints = try src.exprs.ints.clone(gpa);
        for (src.exprs.logic.items) |literal| {
            var copy = literal;
            copy.planes = try gpa.dupe(u64, literal.planes);
            errdefer gpa.free(copy.planes);
            try self.exprs.logic.append(gpa, copy);
        }
        self.stmts = try src.stmts.clone(gpa);
        self.blocks = try src.blocks.clone(gpa);
        self.stmt_toks = try src.stmt_toks.clone(gpa);
        // Attribute specs are immutable borrowed declaration data; owner
        // rows are copied because a resumed parser appends/reclassifies them.
        self.attributes = try src.attributes.clone(gpa);
        // Vendor-attribute rows name statements and expressions by id, which
        // the copied columns keep valid.
        self.lte_attrs = try src.lte_attrs.clone(gpa);
        // Rows only: the index slices are borrowed, like the decl slices.
        self.hier_indices = try src.hier_indices.clone(gpa);
        self.modules = src.modules;
        self.disciplines = src.disciplines;
        self.natures = src.natures;
        self.paramsets = src.paramsets;
        self.connectrules = src.connectrules;
        self.udps = src.udps;
        self.configs = src.configs;
    }

    /// Appends a statement and its token; both columns stay in lockstep, and a
    /// `.block`'s `SeqBlock` goes to `blocks`. On OOM nothing is appended.
    /// Invalidates `seqBlockMut` pointers and `seqBlocks` iterators.
    /// Asserts the pool holds fewer than `maxInt(u32)` statements.
    pub fn addStmt(self: *SourceFile, gpa: std.mem.Allocator, s: Stmt, main_tok: u32) !StmtId {
        const id: u32 = self.baseStmts() + @as(u32, @intCast(self.stmts.items.len));
        std.debug.assert(id != @backingInt(StmtId.none));
        try self.stmts.ensureUnusedCapacity(gpa, 1);
        try self.stmt_toks.ensureUnusedCapacity(gpa, 1);
        if (s == .block) try self.blocks.ensureUnusedCapacity(gpa, 1);
        self.stmts.appendAssumeCapacity(switch (s) {
            .block => |b| blk: {
                self.blocks.appendAssumeCapacity(b);
                break :blk .{ .block = @fromBackingInt(self.baseBlocks() + @as(u32, @intCast(self.blocks.items.len - 1))) };
            },
            inline else => |payload, tag| @unionInit(StmtRow, @tagName(tag), payload), // else: every other arm is stored as it is
        });
        self.stmt_toks.appendAssumeCapacity(main_tok);
        return @fromBackingInt(@intCast(id));
    }

    /// Returns statement `id` by value, since the pool may grow during parsing.
    pub fn stmt(self: *const SourceFile, id: StmtId) Stmt {
        const o = self.baseStmts();
        if (@backingInt(id) < o) return self.base.?.stmt(id);
        return switch (self.stmts.items[@backingInt(id) - o]) {
            .block => |b| .{ .block = self.blocks.items[@backingInt(b) - self.baseBlocks()] },
            inline else => |payload, tag| @unionInit(Stmt, @tagName(tag), payload), // else: every other arm is stored as it is
        };
    }

    /// Returns the token statement `id` is reported at.
    pub fn stmtTok(self: *const SourceFile, id: StmtId) u32 {
        const o = self.baseStmts();
        if (@backingInt(id) < o) return self.base.?.stmtTok(id);
        return self.stmt_toks.items[@backingInt(id) - o];
    }

    /// Returns the §5.3.2 block statement `id` for in-place editing (the
    /// parser names a generate block after the fact, §6.6.3). Asserts `id`
    /// is a `.block` and this file is a parse. Invalidated by the next
    /// `addStmt`.
    pub fn seqBlockMut(self: *SourceFile, id: StmtId) *SeqBlock {
        std.debug.assert(self.base == null);
        return &self.blocks.items[@backingInt(self.stmts.items[@backingInt(id)].block)];
    }

    /// Returns an iterator over every §5.3.2 block statement in the pool, in
    /// statement order (an overlay's base's first), for a pass that wants
    /// every block's declarations.
    pub fn seqBlocks(self: *const SourceFile) SeqBlockIterator {
        const first: []const SeqBlock = if (self.base) |b| b.blocks.items else &.{};
        return .{ .first = first, .then = self.blocks.items };
    }

    /// See `seqBlocks`. Valid until the next `addStmt`.
    const SeqBlockIterator = struct {
        /// The base's blocks, then this file's own.
        first: []const SeqBlock,
        then: []const SeqBlock,
        i: u32 = 0,

        /// Returns the next block, or null after the last.
        pub fn next(it: *SeqBlockIterator) ?*const SeqBlock {
            if (it.i == it.first.len + it.then.len) return null;
            defer it.i += 1;
            return if (it.i < it.first.len) &it.first[it.i] else &it.then[it.i - it.first.len];
        }
    };

    // The statement walks (ast_stmt.zig) and the nature walk (ast_decl.zig),
    // callable as methods.
    pub const Edge = stmt_file.Edge;
    pub const stmtEdges = stmt_file.stmtEdges;
    pub const stmtWrites = stmt_file.stmtWrites;
    pub const lvalueBase = stmt_file.lvalueBase;

    /// Returns the interned name `id`; asserts `id != .none`.
    pub fn str(self: *const SourceFile, id: StrId) []const u8 {
        return self.strings.get(id);
    }

    /// Interns `s`, which is borrowed and must outlive the file.
    pub fn intern(self: *SourceFile, gpa: std.mem.Allocator, s: []const u8) !StrId {
        return self.strings.intern(gpa, s);
    }

    pub const natureAttrExpr = decl_file.natureAttrExpr;
};

test {
    _ = expr_file;
    _ = decl_file;
    _ = stmt_file;
}

const testing = std.testing;

test "the module views partition `modules` in order, counts clamped to its length" {
    var mods: [5]ModuleDecl = undefined;
    for (&mods, 0..) |*m, i| m.* = .{ .name = @fromBackingInt(@as(u32, @intCast(i))), .ports = &.{} };
    var f: SourceFile = .{ .modules = &mods };
    for (0..8) |builtin| {
        for (0..8) |netlist| {
            f.builtin_modules = @intCast(builtin);
            f.netlist_modules = @intCast(netlist);
            const table = f.tablePrimitives();
            const net = f.netlistModules();
            const user = f.userModules();
            // Table E.1, then the netlist's modules, then the user's: contiguous.
            try testing.expect(table.ptr == f.modules.ptr);
            try testing.expect(net.ptr == f.modules.ptr + table.len);
            try testing.expect(user.ptr == f.modules.ptr + table.len + net.len);
            try testing.expectEqual(mods.len, table.len + net.len + user.len);
            const prelude = @min(builtin, mods.len);
            try testing.expectEqual(prelude, table.len + net.len);
            try testing.expectEqual(@min(netlist, prelude), net.len);
        }
    }
}

test "stmtLte/exprLte: the last attribute of the kind wins; other kinds and owners do not count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: SourceFile = .empty;
    const s: StmtId = @fromBackingInt(3);
    const e: ExprId = @fromBackingInt(5);
    const v: ExprId = @fromBackingInt(10);
    try f.lte_attrs.append(a, .{ .kind = .vera_lte, .stmt = s, .value = v, .main_tok = 1 });
    try f.lte_attrs.append(a, .{ .kind = .vera_interp, .stmt = s, .value = v, .main_tok = 2 });
    try f.lte_attrs.append(a, .{ .kind = .vera_lte, .stmt = s, .value = v, .main_tok = 3 });
    try f.lte_attrs.append(a, .{ .kind = .vera_lte, .expr = e, .value = v, .main_tok = 4 });
    try testing.expectEqual(@as(u32, 3), f.stmtLte(s, .vera_lte).?.main_tok);
    try testing.expectEqual(@as(u32, 2), f.stmtLte(s, .vera_interp).?.main_tok);
    try testing.expectEqual(null, f.stmtLte(s, .vera_nodiff));
    try testing.expectEqual(null, f.stmtLte(@fromBackingInt(4), .vera_lte));
    try testing.expectEqual(@as(u32, 4), f.exprLte(e, .vera_lte).?.main_tok);
    try testing.expectEqual(null, f.exprLte(e, .vera_interp));
}

test "addStmt/stmt round-trip every arm, and the token column follows" {
    const gpa = testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const e: ExprId = @fromBackingInt(1);
    const s: StmtId = @fromBackingInt(0);
    const arms = [_]Stmt{
        .empty,
        .{ .block = .{ .name = @fromBackingInt(2), .parallel = true, .body = &.{s} } },
        .{ .assign = .{ .target = e, .value = e, .nonblocking = true, .timing = e, .timing_is_delay = true, .timing_repeat = e, .timing_implicit = true, .continuous = .force } },
        .{ .contribute = .{ .lhs = e, .rhs = e } },
        .{ .indirect = .{ .lhs = e, .probe = e, .eqn = e } },
        .{ .if_stmt = .{ .cond = e, .then_s = s, .else_s = .none, .is_generate = true } },
        .{ .case_stmt = .{ .kind = .casez, .scrutinee = e, .arms = &.{.{ .labels = &.{e}, .body = s }} } },
        .{ .for_stmt = .{ .init = s, .cond = e, .step = s, .body = s } },
        .{ .while_stmt = .{ .cond = e, .body = s } },
        .{ .repeat_stmt = .{ .count = e, .body = s } },
        .{ .event_control = .{ .event = e, .body = s, .kind = .level } },
        .{ .event_trigger = .{ .target = e } },
        .{ .disable = .{ .name = @fromBackingInt(3) } },
        .{ .sys_task = .{ .name = @fromBackingInt(4), .args = &.{ e, .none } } },
        .{ .jump = .{ .kind = .ret, .value = e } },
    };
    // One of each arm, so a new arm must be added here.
    comptime std.debug.assert(arms.len == @typeInfo(Stmt).@"union".field_names.len);
    for (arms, 0..) |arm, i| {
        const id = try f.addStmt(gpa, arm, @intCast(i));
        try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(id));
        try testing.expect(std.meta.eql(arm, f.stmt(id)));
        try testing.expectEqual(@as(u32, @intCast(i)), f.stmtTok(id));
    }
    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
}

fn addStmtsOom(gpa: std.mem.Allocator) !void {
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    for (0..20) |i| {
        const rows = f.stmts.items.len;
        const blocks = f.blocks.items.len;
        const s: Stmt = if (i % 3 == 0) .{ .block = .{} } else .empty;
        _ = f.addStmt(gpa, s, @intCast(i)) catch |err| {
            // Nothing is appended, to any of the three columns.
            try testing.expectEqual(rows, f.stmts.items.len);
            try testing.expectEqual(rows, f.stmt_toks.items.len);
            try testing.expectEqual(blocks, f.blocks.items.len);
            return err;
        };
    }
    try testing.expectEqual(@as(usize, 7), f.blocks.items.len);
}

test "addStmt appends nothing on OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, addStmtsOom, .{});
}

test "deinit frees every store it appends to, the vendor attributes included" {
    const gpa = testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const one = try f.exprs.addInt(gpa, 0, 1);
    const s = try f.addStmt(gpa, .empty, 0);
    _ = try f.addStmt(gpa, .{ .block = .{ .body = &.{s} } }, 0);
    _ = try f.intern(gpa, "x");
    try f.attributes.append(gpa, .{ .owner = .{ .kind = .statement, .tok = 0 }, .specs = &.{} });
    // `testing.allocator` reports this row as a leak unless `deinit` frees it.
    try f.lte_attrs.append(gpa, .{ .stmt = s, .value = one, .main_tok = 0 });
}

test "seedFrom copies the growing stores, borrows the decls, and the copy grows alone" {
    const gpa = testing.allocator;
    var src: SourceFile = .empty;
    defer src.deinit(gpa);
    const x = try src.intern(gpa, "x");
    const one = try src.exprs.addInt(gpa, 0, 1);
    const planes = try gpa.dupe(u64, &.{ 1, 0 });
    _ = try src.exprs.addLogic(gpa, 1, .{ .width = 1, .sized = true, .signed = false, .planes = planes });
    const s = try src.addStmt(gpa, .empty, 2);
    _ = try src.addStmt(gpa, .{ .block = .{ .body = &.{s} } }, 3);
    try src.attributes.append(gpa, .{ .owner = .{ .kind = .statement, .tok = 2 }, .specs = &.{} });
    try src.lte_attrs.append(gpa, .{ .stmt = s, .value = one, .main_tok = 2 });
    const mods = [_]ModuleDecl{.{ .name = x, .ports = &.{} }};
    const udps = [_]UdpDecl{.{ .name = x }};
    const configs = [_]ConfigDecl{.{ .name = x, .design = &.{}, .rules = &.{}, .main_tok = 0 }};
    src.modules = &mods;
    src.udps = &udps;
    src.configs = &configs;

    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    try f.seedFrom(gpa, &src);
    try testing.expectEqual(x, f.strings.find("x").?);
    try testing.expectEqual(@as(i64, 1), f.exprs.intValue(one));
    try testing.expectEqual(s, f.stmt(@fromBackingInt(1)).block.body[0]);
    try testing.expectEqual(@as(u32, 3), f.stmtTok(@fromBackingInt(1)));
    try testing.expectEqual(@as(usize, 1), f.attributes.items.len);
    const lte = f.stmtLte(s, .vera_lte) orelse return error.TestExpectedLteAttr;
    try testing.expectEqual(one, lte.value);
    try testing.expect(f.modules.ptr == src.modules.ptr);
    try testing.expect(f.udps.ptr == src.udps.ptr);
    try testing.expect(f.configs.ptr == src.configs.ptr);
    // The logic planes are the copy's own; `deinit` frees each once.
    try testing.expect(f.exprs.logic.items[0].planes.ptr != planes.ptr);

    // Appending to the copy leaves the source alone.
    _ = try f.intern(gpa, "y");
    _ = try f.addStmt(gpa, .empty, 4);
    try f.lte_attrs.append(gpa, .{ .stmt = s, .value = one, .main_tok = 4 });
    try testing.expectEqual(@as(?StrId, null), src.strings.find("y"));
    try testing.expectEqual(@as(usize, 2), src.stmts.items.len);
    try testing.expectEqual(@as(usize, 1), src.lte_attrs.items.len);
}

/// The appends the overlay test makes: `n` = 0 the parse's half, 1 the
/// overlay's.
fn appendFileHalf(f: *SourceFile, gpa: std.mem.Allocator, n: u32) !StmtId {
    _ = try f.intern(gpa, "x");
    const e = try f.exprs.addInt(gpa, n, n);
    _ = try f.addStmt(gpa, .{ .contribute = .{ .lhs = e, .rhs = e } }, 10 + n);
    return f.addStmt(gpa, .{ .block = .{ .name = try f.intern(gpa, if (n == 0) "x" else "y") } }, 20 + n);
}

test "overlay: the parse's ids read through it, its own continue them, and the parse never changes" {
    const gpa = testing.allocator;
    var parse: SourceFile = .empty;
    defer parse.deinit(gpa);
    const b0 = try appendFileHalf(&parse, gpa, 0);
    try parse.lte_attrs.append(gpa, .{ .stmt = b0, .value = .none, .main_tok = 0 });
    const mods = [_]ModuleDecl{.{ .name = parse.strings.find("x").?, .ports = &.{} }};
    parse.modules = &mods;
    var f: SourceFile = .overlay(&parse, .{ .builtin_modules = 1 });
    defer f.deinit(gpa);
    const b1 = try appendFileHalf(&f, gpa, 1);
    // The oracle: one file doing the same appends in the same order.
    var one: SourceFile = .empty;
    defer one.deinit(gpa);
    try testing.expectEqual(b0, try appendFileHalf(&one, gpa, 0));
    try testing.expectEqual(b1, try appendFileHalf(&one, gpa, 1));
    for (0..4) |i| {
        const id: StmtId = @fromBackingInt(@intCast(i));
        try testing.expectEqual(std.meta.activeTag(one.stmt(id)), std.meta.activeTag(f.stmt(id)));
        try testing.expectEqual(one.stmtTok(id), f.stmtTok(id));
    }
    try testing.expectEqual(one.stmt(b1).block.name, f.stmt(b1).block.name);
    try testing.expectEqual(one.stmt(@fromBackingInt(2)).contribute.lhs, f.stmt(@fromBackingInt(2)).contribute.lhs);
    try testing.expectEqual(one.exprs.len(), f.exprs.len());
    try testing.expectEqual(one.strings.find("y").?, f.strings.find("y").?);
    var blocks = f.seqBlocks();
    try testing.expectEqual(f.stmt(b0).block.name, blocks.next().?.name);
    try testing.expectEqual(f.stmt(b1).block.name, blocks.next().?.name);
    try testing.expectEqual(null, blocks.next());
    // Borrowed from the parse, and the caller's fields are the overlay's.
    try testing.expect(f.modules.ptr == parse.modules.ptr);
    try testing.expectEqual(b0, f.stmtLte(b0, .vera_lte).?.stmt);
    try testing.expectEqual(@as(u32, 1), f.builtin_modules);
    try testing.expectEqual(@as(u32, 0), parse.builtin_modules);
    // The parse holds only its own half.
    try testing.expectEqual(@as(usize, 2), parse.stmts.items.len);
    try testing.expectEqual(@as(u32, 1), parse.exprs.len());
    try testing.expectEqual(@as(?StrId, null), parse.strings.find("y"));
}

fn seedOom(gpa: std.mem.Allocator, src: *const SourceFile) !void {
    var f: SourceFile = .empty;
    // On OOM `f` holds a partial copy, which `deinit` frees.
    defer f.deinit(gpa);
    try f.seedFrom(gpa, src);
    try testing.expectEqual(src.stmts.items.len, f.stmts.items.len);
    try testing.expectEqual(src.exprs.logic.items.len, f.exprs.logic.items.len);
}

test "seedFrom on OOM leaves a partial copy that deinit frees, at every allocation" {
    const gpa = testing.allocator;
    var src: SourceFile = .empty;
    defer src.deinit(gpa);
    _ = try src.intern(gpa, "x");
    const one = try src.exprs.addInt(gpa, 0, 1);
    _ = try src.exprs.addReal(gpa, 0, 0.5);
    for (0..3) |k| {
        const planes = try gpa.dupe(u64, &.{ k, 0 });
        _ = src.exprs.addLogic(gpa, 1, .{ .width = 1, .sized = true, .signed = false, .planes = planes }) catch |e| {
            gpa.free(planes);
            return e;
        };
    }
    _ = try src.exprs.addExprList(gpa, &.{one});
    const s = try src.addStmt(gpa, .empty, 2);
    _ = try src.addStmt(gpa, .{ .block = .{ .body = &.{s} } }, 3);
    try src.attributes.append(gpa, .{ .owner = .{ .kind = .statement, .tok = 2 }, .specs = &.{} });
    try src.lte_attrs.append(gpa, .{ .stmt = s, .value = one, .main_tok = 2 });
    try testing.checkAllAllocationFailures(gpa, seedOom, .{&src});
}
