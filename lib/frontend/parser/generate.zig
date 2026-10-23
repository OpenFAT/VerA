//! Annex A.4.2 generate constructs (LRM §6.6): generate regions, loop and
//! conditional generates -> an `Ast.AnalogBlock` whose body is the `for`,
//! `if` or `case`, which lowering unrolls or folds (§6.6.1).
//!
//! LRM clauses cited: §2.8, §3.4.6, §3.5, §5.2.1, §5.9.2, §5.10.4, §6.5, §6.6,
//! §6.6.1, §6.6.2, §6.6.3, §6.8, §6.9.1, §12.4.2.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.4.2 generate constructs: LRM §6.6
//
// A generate construct becomes one `Ast.AnalogBlock` whose body is the
// `for`/`if` statement, with the generated blocks spliced in as statements.
// `Lower.tryUnrollFor` unrolls a genvar `for` with the genvar bound as
// §6.6.1's implicit localparam, and folds a constant `if` the same way.
// §6.9.1 concatenates a module's analog blocks in source order, and
// unrolling order is source order, so a generated block lands in the slot
// it would occupy written out by hand.
// -----------------------------------------------------------------------

/// Parses one generate construct (`kind` is `for`, `if` or `case`) and
/// appends it to `b.analog`. `gen_construct` is bumped only on the outermost
/// construct, which makes §6.6.2's two naming rules one test: arms of one
/// conditional construct "may have the same name" and share the id, while
/// blocks of "any other generate construct in the same scope" get another.
/// An `else if` chain nests in the outer construct's block, so it inherits
/// the id, which is §6.6.2's direct-nesting exception.
pub fn parseGenerate(self: *Parser, b: *parse_module.Body, comptime kind: token.Tag) Error!void {
    if (self.gen_construct_depth == 0) self.gen_construct += 1;
    b.gen_count += 1; // §6.6.3 this construct's number in its scope
    self.gen_construct_depth += 1;
    self.gen_depth += 1;
    defer {
        self.gen_construct_depth -= 1;
        self.gen_depth -= 1;
    }
    const tok = self.pos;
    const s = switch (kind) {
        .kw_for => try parseFor(self, b, tok),
        .kw_if => try parseIf(self, b, tok),
        .kw_case => try parse_stmt.parseCase(self, .normal, b),
        else => unreachable, // else: the caller dispatched on exactly these three
    };
    try b.analog.append(self.arena, .{ .body = s, .main_tok = tok });
}

/// Syntax 6-8 `loop_generate_construct ::= for ( genvar_initialization ;
/// genvar_expression ; genvar_iteration ) generate_block`.
///
/// The parts have the shape of §5.9.2's `for`, and the same node carries
/// them: lowering tells the two apart by looking the loop variable up in
/// `ModuleDecl.genvars` (§3.5). Lowering also owns the non-constant scheme
/// diagnostics (E0417 to E0420), which replace the if/case forms' E0428.
///
/// `gen` is a `*parse_module.Body` for a generate construct, or comptime
/// `null` for an analog `for` statement; `inline` specializes each.
pub inline fn parseFor(self: *Parser, gen: anytype, tok: u32) Error!Ast.StmtId {
    self.pos += 1; // 'for'
    _ = try self.expect(.lparen);
    // A.4.2 `genvar_initialization ::= genvar_identifier = constant_expression`:
    // checked against the module's genvars by `checkGenBlockNames`.
    if (@TypeOf(gen) != @TypeOf(null) and self.identLike(self.pos))
        try gen.gen_loops.append(self.arena, .{ .name = try self.internTok(self.pos), .tok = self.pos, .construct = self.gen_construct });
    const init_s = try parse_stmt.parseAssignNoSemi(self);
    _ = try self.expect(.semicolon);
    const cond = try parse_expr.parseExpr(self);
    _ = try self.expect(.semicolon);
    const step = try parse_stmt.parseAssignNoSemi(self);
    _ = try self.expect(.rparen);
    if (@TypeOf(gen) != @TypeOf(null)) self.gen_loop_body = true;
    const body = if (@TypeOf(gen) == @TypeOf(null)) try parse_stmt.parseStmt(self) else try parseGenerateBlock(self, gen);
    return self.file.addStmt(self.arena, .{ .for_stmt = .{
        .init = init_s,
        .cond = cond,
        .step = step,
        .body = body,
    } }, tok);
}

/// Syntax 6-8 `if_generate_construct ::= if ( constant_expression )
/// generate_block [ else generate_block ]`.
///
/// `gen` is as for `parseFor`. `else if` needs no arm of its own: an
/// if_generate_construct is itself a module_or_generate_item, so the chain is
/// a one-item generate_block that `parseGenerateBlock` reaches through
/// `parseModuleItem`.
pub inline fn parseIf(self: *Parser, gen: anytype, tok: u32) Error!Ast.StmtId {
    self.pos += 1; // 'if'
    _ = try self.expect(.lparen);
    const cond = try parse_expr.parseExpr(self);
    _ = try self.expect(.rparen);
    const then_s = if (@TypeOf(gen) == @TypeOf(null)) try parse_stmt.parseStmt(self) else try parseGenerateBlock(self, gen);
    const else_s: Ast.StmtId = if (self.eat(.kw_else))
        if (@TypeOf(gen) == @TypeOf(null)) try parse_stmt.parseStmt(self) else try parseGenerateBlock(self, gen)
    else
        .none;
    return self.file.addStmt(
        self.arena,
        .{
            .if_stmt = .{
                .cond = cond,
                .then_s = then_s,
                .else_s = else_s,
                // §6.6's "all expressions in generate schemes shall be constant
                // expressions" is judged in lowering (E0428), which is the only
                // stage that can evaluate one.
                .is_generate = @TypeOf(gen) != @TypeOf(null),
            },
        },
        tok,
    );
}

/// Syntax 6-8 `generate_block ::= module_or_generate_item | begin
/// [ : generate_block_identifier ] { module_or_generate_item } end`.
///
/// The items are collected into a scratch `Body` and split by scope. §6.6
/// gives the block its own scope, so its parameters and variables become the
/// `SeqBlock`'s; branches, genvars and analog functions are hoisted to the
/// module. Instances, and in a digital parse nets, events, processes and
/// drivers, stay on the block (`Ast.GenItems`). Analog nets are hoisted.
/// Defparams and tasks, whose
/// existence the scheme decides but that have no home yet, are E0235.
///
/// ponytail: analog-net hoisting is right for a conditional generate, which
/// elaborates at most once, and short of the LRM for a loop generate, which should get
/// one renamed copy of each declaration per iteration (§6.6.1 names them
/// `blk[0].n`). The analog copies have to be made in `Lower.tryUnrollFor`
/// where the trip count is known, not here where it is not. Digital execution
/// declares each iteration's own nets from `Ast.GenItems` in its block scope.
pub fn parseGenerateBlock(self: *Parser, b: *parse_module.Body) Error!Ast.StmtId {
    if (self.segmentDue()) return self.segment(parseGenerateBlock, .{ self, b });
    self.enter();
    defer self.leave();
    const tok = self.pos;
    const loop_body = self.gen_loop_body;
    self.gen_loop_body = false;
    // A.4.2 has no null generate_block, but `if (c) ;` is what a model
    // writes for a deliberately empty arm and refusing it would only move
    // the error off the rule the source actually breaks.
    if (self.eat(.semicolon)) return self.file.addStmt(self.arena, .empty, tok);

    var blk: Ast.SeqBlock = .{};
    var gb: parse_module.Body = .{};
    // §6.6.2 direct nesting (IEEE 1364-2005 §12.4.2): a generate block that is
    // one conditional generate construct with no begin/end "is not treated as a
    // separate scope", and its blocks are named as the enclosing construct's
    // (§6.6.3), so the inner construct takes the outer number.
    var direct = false;
    if (self.eat(.kw_begin)) {
        if (self.eat(.colon)) {
            const name_tok = self.pos;
            blk.name = try self.expectIdent();
            // §6.6.1: a named generate block "is a declaration of an array of
            // generate block instances"; §6.6.2: "its name declares a generate
            // block instance". Either way the name is declared in the
            // enclosing scope; `checkGenBlockNames` enforces it.
            try b.gen_blocks.append(self.arena, .{
                .name = blk.name,
                .tok = name_tok,
                .construct = self.gen_construct,
            });
        }
        // An item, or `recoverStatement`'s one token at least.
        var before: u32 = undefined;
        while (self.peek() != .kw_end and self.peek() != .eof) : (std.debug.assert(self.pos > before)) {
            const attr_at = self.pos;
            try self.skipAttributes();
            // An attribute instance can be the last thing in the file (#48):
            // `expect(.kw_end)` below reports the unclosed block, and
            // `parseModuleItem` must not fail on `.eof` without consuming.
            // Before `end` or end of file it prefixes nothing (#49).
            if (self.peek() == .kw_end or self.peek() == .eof) {
                try self.attributesEnd(attr_at);
                break;
            }
            before = self.pos;
            parse_module.parseModuleItem(self, &gb) catch |e| {
                if (e == error.OutOfMemory) return e;
                self.recoverStatement(before);
            };
        }
        _ = try self.expect(.kw_end);
    } else {
        try self.skipAttributes();
        direct = !loop_body and (self.peek() == .kw_if or self.peek() == .kw_case);
        if (direct) gb.gen_count = b.gen_count - 1;
        try parse_module.parseModuleItem(self, &gb);
    }

    // ponytail: `analog initial` (§5.2.1) inside a generate block is spliced
    // onto the ordinary spine like any other analog construct, so it loses its
    // initialization-only scheduling. Give `Ast.SeqBlock` an is_initial flag,
    // or hand the block back to `b.analog`, when a model needs one.
    const body = try self.arena.alloc(Ast.StmtId, gb.analog.items.len);
    for (gb.analog.items, body) |ab, *s| s.* = ab.body;
    blk.params = gb.params.items;
    blk.vars = gb.vars.items;
    blk.body = body;

    for (gb.ports.items) |p| try parse_module.addPort(self, b, p);
    try b.aliasparams.appendSlice(self.arena, gb.aliasparams.items);
    // A digital parse keeps the block's nets on the block (§12.4: one set per
    // loop iteration, in the block's scope); the analog pipeline hoists them.
    if (!self.digital) try b.nets.appendSlice(self.arena, gb.nets.items);
    try b.branches.appendSlice(self.arena, gb.branches.items);
    // §6.6: a generate block "brings the objects, behavioral constructs, and
    // module instances within the block into existence" only as its scheme
    // selects. Instances stay on the block: the digital engine decides their
    // scheme (`lib/sim/digital/root.zig`), and analog elaboration gates an
    // if-generate's instances and refuses the rest (`Flatten.genInstances`).
    // A digital parse keeps the events, processes and drivers on the block
    // too, for the digital engine to elaborate per selected block. An analog
    // parse hoists them, so lowering sees the digital half it reads; a hoisted
    // process is marked `generated`, which sends the module to the kernel,
    // and the kernel's digital parse is the one that decides the scheme.
    // A hoisted defparam or task would exist whatever the scheme said, so
    // those are refused (E0235), and not hoisted, so an enclosing block does
    // not report them again; a digital parse keeps a defparam on the block.
    // Every Body list is hoisted, kept under `blk`, or refused; none may be
    // dropped silently.
    blk.instances = gb.instances.items;
    if (!self.digital) for (gb.defparams.items) |d| try self.report(d.main_tok, .E0235, "a defparam", .{});
    // A digital parse keeps them on the block (IEEE 1364-2005 A.1.5), like
    // its defparams.
    if (!self.digital) for (gb.tasks.items) |t| try self.report(t.main_tok, .E0235, "a task or function declaration", .{});
    if (self.digital) {
        const items = try self.arena.create(Ast.GenItems);
        items.* = .{
            .events = gb.events.items,
            .discrete = gb.discrete.items,
            .assigns = gb.assigns.items,
            .gates = gb.gates.items,
            .pulls = gb.pulls.items,
            .switches = gb.switches.items,
            .defparams = gb.defparams.items,
            .nets = gb.nets.items,
            .tasks = gb.tasks.items,
        };
        blk.gen = items;
    } else {
        for (gb.discrete.items) |*d| d.generated = true;
        for (gb.gates.items) |*g| g.generated = true;
        for (gb.pulls.items) |*g| g.generated = true;
        for (gb.switches.items) |*g| g.generated = true;
        try b.events.appendSlice(self.arena, gb.events.items);
        try b.discrete.appendSlice(self.arena, gb.discrete.items);
        try b.assigns.appendSlice(self.arena, gb.assigns.items);
        try b.gates.appendSlice(self.arena, gb.gates.items);
        try b.pulls.appendSlice(self.arena, gb.pulls.items);
        try b.switches.appendSlice(self.arena, gb.switches.items);
    }
    try b.genvars.appendSlice(self.arena, gb.genvars.items);
    try b.functions.appendSlice(self.arena, gb.functions.items);
    // Nested block names ride up to the module with the nets: VerA has no
    // generate scope to hold them, and each entry's `construct` already says
    // which construct it came from, which is all §6.6.2's check needs.
    try b.gen_blocks.appendSlice(self.arena, gb.gen_blocks.items);
    try b.gen_loops.appendSlice(self.arena, gb.gen_loops.items);
    if (direct) {
        // Not a scope: the inner construct's blocks are named in this one.
        try b.gen_auto.appendSlice(self.arena, gb.gen_auto.items);
    } else {
        try nameGenBlocks(self, &gb);
        blk.gen_name = blk.name;
    }
    const id = try self.file.addStmt(self.arena, .{ .block = blk }, tok);
    if (!direct and blk.name == .none) try b.gen_auto.append(self.arena, .{ .stmt = id, .n = b.gen_count });
    return id;
}

/// Names `b`'s unnamed generate blocks per §6.6.3: "genblk<n> where <n> is the
/// assigned number. If such a name would conflict with an explicitly declared
/// name, leading zeroes are added until the name does not conflict." Call it
/// once `b`'s scope is complete, so a later declaration still counts. Gives up
/// adding zeroes after eight.
pub fn nameGenBlocks(self: *Parser, b: *parse_module.Body) error{OutOfMemory}!void {
    for (b.gen_auto.items) |g| {
        var zeros: usize = 0;
        const name = while (true) : (zeros += 1) {
            const text = try self.arena.print("genblk{s}{d}", .{ ("00000000")[0..@min(zeros, 8)], g.n });
            const id = try self.file.intern(self.arena, text);
            if (zeros >= 8 or !declaredIn(b, id)) break id;
        };
        self.file.seqBlockMut(g.stmt).gen_name = name;
    }
    b.gen_auto.clearRetainingCapacity();
}

/// Whether `name` is explicitly declared in the scope `b` collected: the
/// declaration spaces `checkGenBlockNames` reads, plus instances and events.
fn declaredIn(b: *const parse_module.Body, name: Ast.StrId) bool {
    for (b.gen_blocks.items) |g| if (g.name == name) return true;
    for (b.instances.items) |i| if (i.name == name) return true;
    for (b.events.items) |e| if (e.name == name) return true;
    return inDeclSpaces(b, name);
}

/// Whether `name` is in one of the module's ordinary declaration spaces. Ports
/// count (§6.5's header names are declarations), and so does an aliasparam's
/// own identifier (§3.4.6).
/// ponytail: stdlib membership over interned IDs; index declarations if large
/// modules make these linear scans hot.
fn inDeclSpaces(b: *const parse_module.Body, name: Ast.StrId) bool {
    for (b.aliasparams.items) |a| if (a.alias == name) return true;
    return b.port_index.contains(name) or
        nameIn(Ast.ParamDecl, b.params.items, name) or
        nameIn(Ast.VarDecl, b.vars.items, name) or
        nameIn(Ast.NetDecl, b.nets.items, name) or
        nameIn(Ast.BranchDecl, b.branches.items, name) or
        nameIn(Ast.FuncDecl, b.functions.items, name) or
        std.mem.findScalar(Ast.StrId, b.genvars.items, name) != null;
}

/// Whether an `initial` or `always` names its block `name`, past any timing
/// control: IEEE 1364-2005 §4.11's module name space "unifies the definition
/// of functions, tasks, named blocks, module instances, generate blocks".
fn processBlockNamed(self: *const Parser, b: *const parse_module.Body, name: Ast.StrId) bool {
    for (b.discrete.items) |d| {
        var s = d.body;
        while (true) switch (self.file.stmt(s)) {
            .event_control => |ec| s = ec.body,
            .block => |blk| {
                if (blk.name == name) return true;
                break;
            },
            else => break, // else: any other statement names no block
        };
    }
    return false;
}

/// Reports E0238 for a loop generate whose variable is not a declared genvar,
/// and E0230 for a named generate block whose name clashes with another
/// declaration in the scope (§6.6.1, §6.6.2, §6.8). A block name is a
/// declaration whether or not the scheme selects the block, so the scheme is
/// not consulted. Call it once at the end of the module, since a clashing
/// declaration may follow the construct. Reports and carries on; only OOM
/// propagates.
///
/// ponytail: two named blocks collide only across different outermost
/// constructs, so a loop generate nested inside one arm of a conditional is
/// let off too, which §6.6.2 does not license. Keying on the construct itself
/// needs generate blocks to be real scope objects, which §6.6.3 hierarchical
/// names want as well.
pub fn checkGenBlockNames(self: *Parser, b: *parse_module.Body) error{OutOfMemory}!void {
    // A.4.2 `genvar_initialization ::= genvar_identifier = constant_expression`,
    // and a genvar_identifier is what a `genvar_declaration` introduces.
    for (b.gen_loops.items) |l| if (std.mem.findScalar(Ast.StrId, b.genvars.items, l.name) == null)
        try self.report(l.tok, .E0238, "`{s}`", .{self.file.strings.get(l.name)});
    for (b.gen_blocks.items, 0..) |g, i| {
        const clash = inDeclSpaces(b, g.name) or processBlockNamed(self, b, g.name) or
            nameIn(Ast.Subroutine, b.tasks.items, g.name) or
            other: {
                for (b.gen_blocks.items[0..i]) |h| {
                    if (h.name == g.name and h.construct != g.construct) break :other true;
                }
                break :other false;
            };
        if (clash) try self.report(g.tok, .E0230, "`{s}`", .{
            self.file.strings.get(g.name),
        });
    }
}

/// Whether `name` is the `.name` of one of `decls`. Comparing `StrId`s
/// compares names because identifiers are interned.
fn nameIn(comptime T: type, decls: []const T, name: Ast.StrId) bool {
    for (decls) |d| if (d.name == name) return true;
    return false;
}
