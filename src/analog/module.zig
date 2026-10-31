//! The pass's spine: a parsed `Ast.SourceFile` in, the `Lowered` tables and
//! the module's `Mir` out. `lowerFile` elaborates the file (§6.2.2) into one
//! flat module and `lowerModule` lowers it in the pass's order: disciplines,
//! parameters, ports and nets, branches, variables, the analog blocks, then
//! the end-of-block reads and finishers. Each step is one line calling the
//! file that owns its table.
//!
//! Cites: §2.6.1, §2.9, §3.2, §3.4, §3.4.7, §3.5, §3.6.1, §3.6.2, §3.6.3,
//! §3.6.4, §3.12, §3.12.1, §3.13, §4.5.2, §4.7.3, §5.2, §5.2.1, §5.4.1,
//! §5.4.3, §5.6.1.2, §5.6.1.3, §5.6.8.1, §5.10, §5.10.4, §6.2, §6.2.2,
//! §6.3.4, §6.5, §6.5.7.1, §6.8, §6.9, §6.9.1, §7.2.2, §7.3.1, §7.3.6.5, §7.4,
//! §8.5.3.5, §9.4, §9.17, §9.17.3, §9.18, §10.2, §10.3, A.6.2; IEEE 1364-2005
//! §19.1, §19.2, §19.8, §19.9.
//!
//! Contents:
//! - `pub fn lowerFile(self: *Lower) Lower.Error!Lowered`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const constfold = @import("frontend").constfold;
const Elaborate = @import("elab").Elaborate;
const Lower = @import("Lower.zig");
const lower_context = @import("context.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_discipline = @import("discipline.zig");
const lower_event = @import("event.zig");
const lower_expr = @import("expr.zig");
const lower_func = @import("func.zig");
const lower_node = @import("node.zig");
const lower_param = @import("param.zig");
const lower_shape = @import("shape.zig");
const lower_stmt = @import("stmt.zig");
const lower_systask = @import("systask.zig");
const lower_var = @import("var.zig");
const lower_expr_access = @import("expr_access.zig");
const Lowered = Lower.Lowered;
const Oom = Lower.Oom;
const Error = Lower.Error;
const Harness = Lower.Harness;
const expectBodyVerdict = Lower.expectBodyVerdict;
const ground = Lower.ground;

/// Elaborates the file (§6.2.2) into one flat module, then lowers it. Asserts
/// that `self` is fresh from `Lower.init` (its `mir` holds no block). On any
/// error the arena keeps what was built and `self.out` is not to be read.
/// Errors: `DiagnosticsReported` when any error went to the bag (the
/// four-state literal scan stops before elaboration; elaboration and the
/// module's lowering run whole first), `NoModule` when the file has no module.
pub fn lowerFile(self: *Lower) Error!Lowered {
    assert(self.mir.blockCount() == 0);
    assert(!self.had_error);
    try rejectFourStateLiterals(self);
    if (self.had_error) return error.DiagnosticsReported;
    const design = try Elaborate.elaborate(.{
        .arena = self.arena,
        .file = self.file,
        .src = self.src,
        .tok_starts = self.tok_starts,
        .bag = self.bag,
        .param_overrides = self.opts.param_overrides,
        .discipline_resolution = self.opts.discipline_resolution,
        .default_disciplines = self.opts.directives.disciplines,
    });
    self.design = design;
    self.out.hier_names = design.names;
    self.out.inserts = design.inserts;
    // IEEE 1364 §19.2 on §3.6.5's STRUCTURAL implicit nets, which is the half
    // elaboration made but could not judge. Before `lowerModule`, so a design
    // built on a mistyped instance terminal fails at the mistype, not at a
    // later E0337 on the invented floating node.
    for (design.implicit_nets) |n| try lower_node.rejectImplicitNet(self, n.name, n.main_tok);
    try lowerModule(self, design.top);
    if (self.had_error) return error.DiagnosticsReported;
    try lower_node.collectSignalAbstols(self, design.signal_disciplines);
    assert(self.module == design.top);
    return lowered(self);
}

// ---- private ----

/// §2.6.1 every four-state literal outside a mixed module's discrete half is
/// E0130: the current backend only executes two-state analog equations, and
/// the AST keeps full source literals, so nothing may silently coerce them.
/// A mixed module's discrete half is exempt: it runs on the four-state kernel
/// (`markDiscreteExprs`). A two-state literal wider than an i64 is judged where
/// it is lowered: whole in a wide `reg`'s right-hand side (`lower_wide`), E0130
/// as an analog integer (`lower_expr.lowerExpr`).
fn rejectFourStateLiterals(self: *Lower) Oom!void {
    assert(self.mir.blockCount() == 0); // before elaboration and any lowering
    const discrete = try self.arena.alloc(bool, self.file.exprs.len());
    @memset(discrete, false);
    lower_context.markDiscreteExprs(self.file, discrete);
    var refused: u32 = 0;
    for (discrete, 0..) |in_discrete, i| {
        const e: Ast.ExprId = @fromBackingInt(@intCast(i));
        if (self.file.exprs.tag(e) != .logic_literal or in_discrete) continue;
        const literal = self.file.exprs.logicValue(e);
        if (!literal.hasUnknown()) continue; // two-state: `lower_expr` or `lower_wide` lowers it
        const span = self.tokenSpan(self.file.exprs.mainTok(e));
        try self.err(self.file.exprs.mainTok(e), .E0130, "`{s}`: the analog backend cannot execute this {d}-bit four-state literal", .{ self.src[span.start..span.end], literal.width });
        refused += 1;
    }
    if (refused != 0) assert(self.had_error);
}

/// Sizes the MIR from the elaborated AST (`Mir.reserve`): rows per AST
/// expression, `exprs` counted after elaboration, prelude modules included.
//
// The ratios are the median over the 13 compiles with more than 5000
// expressions (the ARPice models, 2026-10-03): instructions 0.59, values
// 0.54, extra words 0.50 per expression. Straight-line compact models sit
// on it (psp103 0.55/0.47/0.23, bsim4va 0.59/0.51/0.52); loop-heavy ones
// run far past it (hisimhv_va 2.04/1.95/6.30, coupled_ltra 8.2/8.0/21.5,
// their Braun phis) and grow from the estimate as before. A large source
// with little analog code (a gate-level `.v`) over-reserves; the tables are
// large blocks of the compile arena's backing allocator, mapped but never
// touched past what lowering writes, so that costs address space, not RSS.
// `max_exprs` caps it at about 30 MB of address space all the same.
fn reserveMir(self: *Lower) Oom!void {
    const max_exprs = 1 << 20;
    assert(self.mir.blockCount() == 0); // before the entry block
    const n: u64 = @min(self.file.exprs.len(), max_exprs);
    try self.mir.reserve(self.arena, @intCast(n * 59 / 100), @intCast(n * 54 / 100), @intCast(n / 2));
    assert(self.mir.insts.capacity >= n * 59 / 100);
}

/// LRM §6.2/§6.9. Register ports (§6.5) into `nodes`, elaborate the
/// declarations, then lower each analog block (§5.2) in source order —
/// multiple analog blocks are executed as if concatenated (§6.9.1).
fn lowerModule(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(self.module == null);
    assert(self.out.nodes.len == 0);
    self.module = module;
    self.mir.name = self.file.str(module.name);
    // IEEE 1364 §19.1 (§10.1 carries it over): the tag of the module keyword's
    // own position, which is what "modules between `celldefine and
    // `endcelldefine" means once the directives are positional regions.
    self.mir.is_cell = Preprocessor.CellRegion.inForce(self.opts.directives.cells, self.tokStart(module.main_tok), false);

    try reserveMir(self);
    const entry = try self.mir.addBlock(self.arena);
    assert(entry == .entry);
    try self.builder.sealBlock(entry);
    self.cur = entry;

    try lower_discipline.collectDisciplines(self); // §3.6.1/§3.6.2 (annex D.1 is inlined here)
    try lower_discipline.checkNatureTable(self); // §3.6.1/§3.13 — the declaration table itself
    try lower_node.checkPortBranchDecls(self); // §3.12.1 — per source module, before flattening's renames matter

    // §3.4 parameters before the ports, because a range is a constant
    // expression over them (§6.5.2.2's `input [1:width] dt`).
    try lower_param.lowerParams(self, module);
    try lower_control.checkParamsetDefparams(self);
    // §9.18 the card-time domain checks: expressions over parameters only.
    for (self.design.system_checks) |c| try self.out.system_checks.append(self.arena, .{
        .kind = c.kind,
        .name = c.name,
        .v = try self.toReal(try lower_expr.lowerExpr(self, c.value)),
    });
    // §7.3.6.5: a mixed module's digital-owned values are host-written inputs.
    // Before the ports and nets, so none of them becomes an analog node.
    try lower_context.declareDiscreteInputs(self, module);
    try lower_context.checkSwitchTerminals(self, module); // A.3.3, §8.5.3.5
    // §8.5.3.5 switch processing is the discrete cycle's; with no discrete
    // half to run it on, the device carries nothing for the switch.
    if (!self.out.mixed_signal) for (module.switches) |sw|
        try self.bag.add(.lower, .W0250, self.tokenSpan(sw.main_tok), "`{s}` switch primitive", .{@tagName(sw.kind)});

    // §6.5 ports first: this order is the host device's terminal order.
    try lower_node.declarePorts(self, module);
    try lower_node.declareNets(self, module); // §3.6.3, §3.6.4
    try lower_node.bindPortConnections(self); // §6.5.7.1
    try lower_node.resolveDisciplines(self, module); // §7.4, §10.2
    // After the parameters and their defaults are in (§6.3.4).
    try lower_param.declareAliasParams(self, module); // §3.4.7
    try lower_node.declareBranches(self, module); // §3.12
    // §5.4.3 each split port's flow probe, whether or not a read of it is
    // lowered: without its branch the port's net would hang free.
    for (self.design.port_ammeters) |am| _ = try lower_expr_access.ammeterFlow(self, am.internal);

    // §3.5 genvars exist only for unrolling; they carry no runtime storage.
    // §3.2/§3.3 module-level variables. The §5.10 scan runs first: whether a
    // variable needs a persistent slot is decided at its declaration, not at
    // the assignment that reveals it (see `holdSlot`).
    try lower_var.markHeldVars(self, module);
    try lower_var.markMemArrays(self, module);
    try lower_var.checkOneItemPerScope(self, module.params, module.vars, module.nets, module.ports);
    // A.6.2 the digital `initial` block, for the same reason and at the same
    // point as the §5.10 scan above: what a variable holds at the top of every
    // evaluation is decided at its declaration. `initial x = 3;` and
    // `integer x = 3;` therefore lower to one write, and the AST edit below is
    // the whole of the difference.
    try lower_context.collectInitialState(self, module);
    const analog_writes = try lower_var.analogWrites(self, module);
    self.analog_writes = analog_writes;
    try declareModuleVars(self, module);
    // §6.8: an `initial` block that assigns a name this module never declared.
    // Reported here because it is only knowable once every declaration is in,
    // and nothing else lowers the block.
    for (self.initial_state.keys(), self.initial_state.values()) |name, a| {
        // A net is declared: writing one is A.6.2's E0482 (`checkDiscreteContext`).
        if (!self.vars.contains(name) and !self.arrays.contains(name) and !lower_context.isNetSpelling(self.file, module, name))
            try self.err(a.tok, .E0313, "`{s}`", .{name});
    }

    try declareEvents(self, module); // §5.10.4

    // §4.7.3, checked on the declarations before any call site sees them.
    try lower_func.checkFuncRecursion(self, module.functions);

    // §2.9/§2.9.2, after the declarations because "constant expression" is a
    // question about the scopes, and before the analog block, so an attribute is
    // reported at its own token rather than after a body that may not compile.
    try lower_param.checkAttributes(self, module.attrs);
    try lower_param.collectDeclMeta(self, module);
    try lower_var.checkScratchOwners(self, module);

    // §7.2.2 the DISCRETE context. Before the analog blocks because the rules
    // below relate the two, and it is the discrete side that names the variables
    // the continuous side is then judged against.
    try lower_context.checkDiscreteContext(self, module);
    try lower_context.checkRegWrites(self, module); // §5.7

    // §9.17.3 the user-function `$limit` state slots, before the body: each
    // slot's previous-iterate read is seeded in the entry block so it dominates
    // the end-of-block read even when the site is under an `if`.
    for (module.analog) |blk| try lower_func.scanCallSites(self, blk.body, true, {}, {});

    // IEEE 1364 §19.9, also before the body and for a related reason: the pull
    // on an unconnected `input` is the OUTSIDE driving the port, so it is there
    // when the child's equations read it, not added after them.
    try lower_node.applyUnconnectedDrive(self);

    // §5.2 analog blocks, concatenated (§6.9.1).
    self.runtime_error_phase = .core;
    for (module.analog, 0..) |blk, bi| {
        self.cur_unit = blk.unit;
        self.cur_block = bi;
        if (blk.is_initial) {
            // §5.2.1 executed once per analysis, before a matrix solution
            // exists. Guarded rather than split into a second CFG so codegen
            // keeps one walk; the guard is a call codegen answers from a flag on
            // the Instance.
            //
            // Not `initial_step`: §5.2.1 says the block "shall be re-executed"
            // for each sub-task of a parameter sweep whose inputs changed, while
            // Table 5-1 makes `initial_step` only the first point of the whole
            // analysis.
            const flag = try self.call("analog_initial", &.{});
            const prev = self.restrict;
            self.restrict = "an analog initial block";
            self.in_analog_initial = true;
            try lower_control.lowerBranchStmt(self, flag, blk.body, .none, false, .none);
            self.in_analog_initial = false;
            self.restrict = prev;
            try lower_systask.haltAfterInitError(self);
        } else {
            try lower_stmt.lowerStmt(self, blk.body);
        }
    }
    self.runtime_error_phase = .none;

    try lower_event.finishTimers(self);

    // §5.6.1.3 the contribution accumulators' final values, and beside each the
    // final value of its retention flag — the "is a value retained [this
    // cycle]?" question the clause's three-way rule turns on.
    try readContribFinals(self, 0);
    // §5.6.8.1 needs the final retention flags just read.
    try lower_contrib.checkSourceLoops(self);
    // §5.10 the same, for every held variable. Reads only (no `call`), so the
    // unit enumeration below is untouched.
    for (self.out.held_vars.items, self.held_places.items) |*h, p| h.final = try self.builder.readVariable(p, self.cur);
    // The same for every operating-point variable, also reads only.
    try readOpVarFinals(self);
    // §5.6.1.2 and the same for every charge site.
    try readSiteFinals(self, 0);
    // §9.17.3 and the same again for every `$limit` state slot: the value the
    // last site on that access function returned this evaluation, or the
    // `$limit$old` seed if none ran.
    for (self.out.limit_slots.items, self.limit_places.items) |*s, p| s.final = try self.builder.readVariable(p, self.cur);
    // VerA's `vera_timepoint` (§2.9): whether each cached statement ran.
    for (self.out.timepoints.items, self.tp_marks.items) |*t, p| t.mark = try self.builder.readVariable(p, self.cur);

    // §9.17 analog kernel control. Emitted last and in this fixed order so the
    // unit enumeration stays a pure function of the source.
    try lower_systask.finishKernelCtl(self);
    // §9.4 display tasks, after the kernel-control calls: those become naming
    // units, and inserting anything ahead would renumber every Instance state
    // field. Deferred §9.4.1 operands are lowered inside, after the accumulator
    // finals above, which is what "converged" means here.
    const contribs_before = self.out.contributions.items.len;
    const sites_before = self.out.charge_sites.items.len;
    try lower_systask.finishDisplays(self);
    // §4.5.2 an operator in a deferred operand adds its unknown's row there.
    try readContribFinals(self, contribs_before);
    try readSiteFinals(self, sites_before);
    if (self.table_effect_place) |p| self.out.table_effect = try self.builder.readVariable(p, self.cur);

    // After `finishDisplays`: a deferred display operand appends its
    // `branch_reads` there, and §1.3.1's probe test has to see every read.
    try lower_contrib.checkProbeBranches(self);
    // Last, so no value numbered above moves.
    try readShareFinals(self);
    assert(self.accum.items.len == self.out.contributions.items.len);
    assert(self.held_places.items.len == self.out.held_vars.items.len);
}

/// §3.2/§3.3 the module-scope variables, each starting every evaluation from
/// its declaration or from the A.6.2 `initial` block's assignment (so
/// `initial x = 3;` and `integer x = 3;` lower to one write). A digital-owned
/// value is a host input, an array one per element, and is skipped. §7.3.1: a
/// wide `reg` the analog context only reads holds its literal for the whole
/// analysis, so every bit of it is known (`reg_consts`).
fn declareModuleVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(self.cur == .entry);
    assert(self.module == module);
    const before = self.vars.count() + self.arrays.count();
    for (module.vars) |*v| {
        // A digital-owned value is a host input, an array one per element.
        if (self.out.discrete_inputs.contains(self.file.str(v.name)) or self.discrete_arrays.contains(self.file.str(v.name))) continue;
        var d = v.*;
        if (self.initial_state.get(self.file.str(d.name))) |a| {
            // §3.2.2 an array takes an assignment pattern, not a scalar, and
            // which element is which is the question a discrete kernel would be
            // answering. E0433 rather than §5.7's E0429 because the refusal is
            // about the block, not about the shapes.
            if (d.dims.len != 0)
                try self.err(a.tok, .E0433, "`{s}` is an array", .{self.file.str(d.name)})
            else
                d.init = a.value;
        }
        try lower_var.declareVarDecl(self, &d, .module);
        // §7.3.1: a wide `reg` the analog context only reads holds its
        // literal for the whole analysis, so every bit of it is known.
        const name = self.file.str(d.name);
        if (self.reg_ranges.get(name)) |rr| if (rr.width > 32 and lower_var.literalReg(self, &d, .module))
            try self.reg_consts.put(self.arena, name, d.init);
    }
    assert(self.vars.count() + self.arrays.count() >= before);
    assert(self.cur == .entry);
}

/// §5.10.4 named events. An event carries no value — only "triggered at this
/// timepoint or not" — so one integer flag per event, zero on entry to every
/// evaluation, set by `-> ev` and tested by `@(ev)`. Each element of an event
/// array is its own flag, scalarized as §3.2 arrays are (`ev[0]`, `ev[1][2]`),
/// so `-> ev[i]` raises exactly one.
///
/// Not a `holdSlot` like an event-assigned variable: a trigger is
/// instantaneous, and a retained flag would leave `@(ev)` active forever
/// (§5.10.4 has no "untrigger").
// ponytail: a detection that lexically precedes its trigger reads 0 and
// never runs. Closing that needs a scheduler queue; §5.10.4's own example
// triggers first.
fn declareEvents(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(self.cur == .entry);
    const before = self.events.count();
    for (module.events) |ev| {
        const name = self.file.str(ev.name);
        if (ev.dims.len == 0) {
            const place = self.builder.newPlace();
            try self.builder.writeVariable(place, self.cur, .zero);
            try self.events.put(self.arena, name, place);
            continue;
        }
        // §5.10.4 an event array: one flag per element, scalarized as §3.2
        // arrays are (`ev[0]`, `ev[1][2]`), so `-> ev[i]` raises exactly one.
        const bounds = (try lower_shape.dimsBounds(self, ev.dims, ev.main_tok, name)) orelse continue;
        var buf: [lower_shape.max_stack_dims]i64 = undefined;
        const idx = try lower_shape.subscriptBuf(self, &buf, bounds.len);
        for (0..lower_shape.shapeCells(bounds)) |k| {
            lower_shape.shapeSubscripts(bounds, k, idx);
            const place = self.builder.newPlace();
            try self.builder.writeVariable(place, self.cur, .zero);
            try self.events.put(self.arena, try lower_shape.elemName(self, name, idx), place);
        }
        try self.event_arrays.put(self.arena, name, bounds);
    }
    assert(self.events.count() >= before);
    assert(self.cur == .entry);
}

/// Reads each contribution's accumulators from `from` on at the end of the
/// block, beside its §5.6.1.3 retention flag.
fn readContribFinals(self: *Lower, from: usize) Oom!void {
    assert(self.accum.items.len == self.out.contributions.items.len); // `newContrib` keeps them parallel
    assert(from <= self.accum.items.len);
    for (self.out.contributions.items[from..], self.accum.items[from..]) |*c, acc| {
        c.resist_val = try self.builder.readVariable(acc.resist, self.cur);
        c.react_val = try self.builder.readVariable(acc.react, self.cur);
        c.wrote_val = try self.builder.readVariable(acc.wrote, self.cur);
    }
    assert(self.blockValid(self.cur));
}

/// Reads, at the end of the block, every module-scope real or integer
/// variable whose `decl_meta` row carries a `desc` or `units` into
/// `Lowered.op_vars`: §3.2.1's output variables, whose values "Verilog-AMS
/// simulators shall provide access to".
/// An array or a string with a `desc` has no single value and is skipped.
fn readOpVarFinals(self: *Lower) Oom!void {
    assert(self.out.op_vars.items.len == 0); // runs once, after the analog blocks
    for (self.out.decl_meta.items) |m| {
        if (m.kind != .variable or (m.desc == null and m.units == null)) continue;
        const slot = self.vars.get(m.name) orelse continue;
        if (slot.ty != .real and slot.ty != .integer) continue;
        try self.out.op_vars.append(self.arena, .{ .name = m.name, .final = try self.builder.readVariable(slot.place, self.cur) });
    }
    assert(self.out.op_vars.items.len <= self.out.decl_meta.items.len);
}

/// Reads each §5.6.1.2 charge site's charge from `from` on at the end of the block.
fn readSiteFinals(self: *Lower, from: usize) Oom!void {
    assert(self.site_places.items.len == self.out.charge_sites.items.len); // `addSite` keeps them parallel
    assert(from <= self.site_places.items.len);
    for (self.out.charge_sites.items[from..], self.site_places.items[from..]) |*s, p| s.final = try self.builder.readVariable(p, self.cur);
    assert(self.blockValid(self.cur));
}

/// §5.4.1 each instance's share of a shared row (`unit_accum`) at the end of
/// the block, sorted by row then unit, into `Lowered.contrib_shares`.
fn readShareFinals(self: *Lower) Oom!void {
    const out = &self.out.contrib_shares;
    assert(out.items.len == 0); // runs once, last: the capacity below is the whole table
    try out.ensureTotalCapacity(self.arena, self.unit_accum.count());
    var it = self.unit_accum.keyIterator();
    while (it.next()) |k| out.appendAssumeCapacity(.{ .row = k.row, .unit = k.unit });
    std.mem.sortUnstable(Lowered.ContribShare, out.items, {}, struct {
        fn lt(_: void, a: Lowered.ContribShare, b: Lowered.ContribShare) bool {
            return a.row < b.row or (a.row == b.row and a.unit < b.unit);
        }
    }.lt);
    for (out.items) |*sh| {
        const pa = self.unit_accum.get(.{ .row = sh.row, .unit = sh.unit }).?;
        sh.resist_val = try self.builder.readVariable(pa.resist, self.cur);
        sh.react_val = try self.builder.readVariable(pa.react, self.cur);
    }
    assert(out.items.len == self.unit_accum.count());
}

/// `out`, plus the inputs lowering read that a later stage still needs. Every
/// buffer is shared with `self`, not copied.
fn lowered(self: *Lower) Oom!Lowered {
    assert(self.out.decl_attrs.len == 0); // once, at the end
    assert(!self.had_error);
    self.out.src = self.src;
    self.out.tok_starts = self.tok_starts;
    self.out.token_span = &Lexer.tokenSpan;
    self.out.default_transitions = self.opts.directives.transitions; // §10.3
    self.out.timescale = self.opts.directives.timescale(); // IEEE 1364 §19.8
    self.out.timescales = self.opts.directives.timescales;
    self.out.decl_attrs = try declAttrs(self);
    self.out.consts = self.consts;
    return self.out;
}

/// §2.9 every attribute_spec on a declaration in the file, in source order
/// (`Lowered.decl_attrs`), each value folded over literals alone. Last, so
/// the AST is complete: nothing after lowering writes it.
fn declAttrs(self: *Lower) Oom![]const Lowered.DeclAttr {
    assert(self.module != null); // the AST is complete
    var out: std.ArrayList(Lowered.DeclAttr) = .empty;
    for (self.file.attributes.items) |b| {
        if (b.owner.kind != .declaration) continue;
        for (b.specs) |s| try out.append(self.arena, .{
            .tok = b.owner.tok,
            .name = self.file.str(s.name),
            .value = if (s.value == .none) .{ .int = 1 } else constfold.fold(self.file, s.value, constfold.literal_env),
        });
    }
    for (out.items) |a| assert(a.tok < self.tok_starts.len or self.tok_starts.len == 0);
    return out.items;
}

/// One generated module for the fuzz test below: up to eight statements
/// drawn from `pool`, legal ones and refused ones, in any order.
fn smithModule(_: void, s: *std.testing.Smith) anyerror!void {
    const pool = [_][]const u8{
        "x = x + 1.0;",
        "if (V(p) > 0.5) x = 2.0; else x = -1.0;",
        "k = (k * 3) % 7;",
        "for (j = 0; j < 3; j = j + 1) x = x + j;",
        "case (k) 0: x = 1.0; 1, 2: x = 2.0; default: x = 0.0; endcase",
        "begin : blk real t; t = x; x = t * 0.5; end",
        "a[k % 3] = x;",
        "x = a[1] + a[k % 3];",
        "while (k > 10) k = k - 1;",
        "repeat (2) x = x * 2.0;",
        "x = ((k != 0) && (1.0 / k > 0.5)) ? 1.0 : 0.0;",
        "I(p) <+ 0.1 * x;",
        "s = {\"a\", \"b\"};",
        "x = sqrt(abs(x)) + min(k, 2) + max(x, 1.0);",
        "@(initial_step) k = 0;",
        "x = ddt(x);",
        // Refused, each by its own rule: E0313, E0318, E0310, E0514.
        "zz = 1.0;",
        "x = ~x;",
        "a[7] = 1.0;",
        "if (k > 2) x = ddt(V(p));",
    };
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const n = s.valueRangeAtMost(u8, 0, 8);
    for (0..n) |_| {
        try body.appendSlice(gpa, "    ");
        try body.appendSlice(gpa, pool[s.index(pool.len)]);
        try body.append(gpa, '\n');
    }
    const src = try gpa.print(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real x;
        \\  real a[0:2];
        \\  integer k, j;
        \\  string s;
        \\  analog begin
        \\{s}
        \\    I(p) <+ x * V(p);
        \\  end
        \\endmodule
    , .{body.items});
    defer gpa.free(src);
    var h: Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    // Every refusal names its reason: `DiagnosticsReported` with an empty bag
    // would be a silent failure.
    const out = try h.lower() orelse return std.testing.expect(h.bag.err_count != 0);
    // What a later stage indexes with is in range.
    try std.testing.expect(out.num_ports <= out.nodes.len);
    for (out.contributions.items) |c| {
        try std.testing.expect(c.hi == ground or c.hi < out.nodes.len);
        try std.testing.expect(c.lo == ground or c.lo < out.nodes.len);
    }
    try std.testing.expectEqual(out.held_vars.items.len, h.low.held_places.items.len);
}

test "lowerFile: a source with no module_declaration (A.1.2) is NoModule" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, "");
    defer h.deinit();
    try std.testing.expectError(error.NoModule, h.lower());
}

test "lowerFile: §2.6.1 a four-state literal is E0130 as a value, and a value under §7.3.2's ===" {
    try expectBodyVerdict("  integer k;", "    k = 4'b1x01;", .E0130);
    // A two-state literal is the integer it spells, however it is written.
    try expectBodyVerdict("  integer k;", "    k = 4'b0101;", null);
    try expectBodyVerdict("  integer k;", "    k = (2 === 4'b1x01);", null);
}

test "lowering a generated module never crashes, and every refusal reports" {
    try std.testing.fuzz({}, smithModule, .{});
}
