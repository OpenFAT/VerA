//! §3.2 variables: scopes, storage and the values one evaluation leaves for
//! the next.
//!
//! In: variable declarations and the module's analog blocks. Out: the `vars`
//! and `arrays` bindings statement lowering assigns through (an SSA place per
//! scalar or scalarized element, one memory-backed storage per runtime-indexed
//! array, `Lowered.mem_arrays`), and a `Lowered.held_vars` row for every
//! variable whose value another evaluation can observe (§5.10 event writes,
//! §3.2 retention).
//!
//! Spine, in `lowerModule`'s order: `markHeldVars` and `markMemArrays` scan
//! the whole module first, because a variable's storage is decided at its
//! declaration, not at the statement that reveals it; then `declareVarDecl`
//! per declaration; `checkScratchOwners` after every declaration is in.
//! After lowering, the spine hands `dropHeld` the held rows `prove`'s
//! `pruneHeld` found unobservable: lowering stays the one writer of
//! `held_vars`.
//!
//! Cites: A.2.7, §2.9, §3.2, §3.2.2, §3.3, §3.4.4, §3.4.8, §3.6.2, §4.2.2,
//! §4.2.7, §5.3.2, §5.4, §5.10, §6.6.1, §6.8, §7, §7.2.2, §7.3.1, §7.3.6.1,
//! §7.3.6.4, §9.4; IEEE 1364-2005 §4.2.2, §5.4.
//!
//! Contents:
//! - `pub const State = struct`
//! - `pub const ScopeEntry = struct`
//! - `pub fn checkOneItemPerScope(self: *Lower, params: []const Ast.ParamDecl, vars: []const Ast.VarDecl, nets: []const Ast.NetDecl, ports: []const Ast.Port) Oom!void`
//! - `pub fn declareVarDecl(self: *Lower, decl: *const Ast.VarDecl, scope: VarScope) Oom!void`
//! - `pub fn literalReg(self: *const Lower, decl: *const Ast.VarDecl, scope: VarScope) bool`
//! - `pub fn countAssign(self: *Lower, place: Ssa.Place) Oom!void`
//! - `pub fn hiddenHeldInt(self: *Lower, name: []const u8) Oom!VarSlot`
//! - `pub fn closeScope(self: *Lower, mark: usize) void`
//! - `pub fn declareArray(self: *Lower, name: []const u8, info: ArrayInfo) Oom!void`
//! - `pub fn declareVar(self: *Lower, name: []const u8, ty: Ty) Oom!VarSlot`
//! - `pub fn isMemArray(self: *const Lower, name: Ast.StrId, ty: Ty) bool`
//! - `pub fn declareMemArray(self: *Lower, name: []const u8, dims: []const lower_shape.Bounds, ty: Ty, zero: bool) Oom!Ssa.Place`
//! - `pub fn storeElem(self: *Lower, place: Ssa.Place, index: Mir.Value, v: Mir.Value) Oom!void`
//! - `pub fn loadElem(self: *Lower, mem: ArrayInfo.Mem, ty: Ty, index: Mir.Value) Oom!Mir.Value`
//! - `pub fn analogRead(self: *Lower, value: Mir.Value, width: ?u32) Oom!Mir.Value`
//! - `pub fn writeElem(self: *Lower, name: []const u8, info: ArrayInfo, idx: []const i64, v: Mir.Value) Oom!void`
//! - `pub fn analogWrites(self: *Lower, module: *const Ast.ModuleDecl) Oom!std.AutoHashMapUnmanaged(Ast.StrId, void)` (`expr`, `stmt`)
//! - `pub fn checkScratchOwners(self: *Lower, module: *const Ast.ModuleDecl) Oom!void` (`expr`, `stmt`)
//! - `pub fn zeroOf(ty: Ty) Mir.Value`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const rules = @import("elab").discipline_rules;
const Lower = @import("Lower.zig");
const lower_held = @import("held.zig");
const lower_constfold = @import("constfold.zig");
const lower_context = @import("context.zig");
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const lower_wide = @import("wide.zig");
const Ssa = @import("ssa.zig");
const lower_noise_src = @import("noise_src.zig");
const HeldFrame = lower_held.HeldFrame;
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const VarSlot = Lower.VarSlot;
const ArrayInfo = Lower.ArrayInfo;
const Const = Lower.Const;
const astTy = Lower.astTy;
const none_u32 = Lower.none_u32;

/// This file's private state on `Lower` (`Lower.var_state`).
pub const State = struct {
    /// Variables `markHeldVars` found assigned under an `@(...)`, collected BEFORE
    /// the module's variables are declared. Empty for a module with no event
    /// control.
    ///
    /// Keyed on §5.3.2's "unique location", i.e. the pair (scope, name) spelled as
    /// a dotted path: a module variable is its bare name, a named block's local is
    /// `<label>.<name>` (`<outer>.<inner>.<name>` when nested). A bare name would
    /// make `lo.n`, `hi.n` and the module's own `n` one slot.
    /// The value says why (`Lower.HeldVar.Why`).
    held_names: std.StringHashMapUnmanaged(Lower.HeldVar.Why) = .empty,
    /// The `held_names` keys an event body writes, true while every such body
    /// waits on explicit D2A terms only (`Lower.HeldVar.d2a`).
    d2a_only: std.StringHashMapUnmanaged(bool) = .empty,
    /// §7.3.6.1 the event-assigned module variables a discrete context reads,
    /// each with the hidden held counter its every assignment increments
    /// (`Lower.HeldVar.assign_count_prefix`).
    assign_counts: std.AutoHashMapUnmanaged(Ssa.Place, Lower.VarSlot) = .empty,
    /// The enclosing NAMED blocks during `scanHeld`, so a target resolves to the
    /// nearest declaration of it — a module variable assigned from inside a block
    /// still keys bare, because the block does not declare it.
    held_frames: std.ArrayList(HeldFrame) = .empty,
    /// §3.2.2 array names some subscript indexes at run time (`markMemArrays`):
    /// `declareVarDecl` gives such an array one memory-backed storage.
    mem_names: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,
    /// `held_names` keys an `analog initial` body or an `@(...)` body writes
    /// AND some read sees before the same evaluation writes them: a value
    /// carried to another evaluation, which `vera_scratch` may not drop (E0536).
    carried: std.StringHashMapUnmanaged(void) = .empty,
    /// The bindings a declaration shadowed, which `closeScope` puts back: a
    /// side table because almost no declaration shadows anything (psp103
    /// logs ~1.5k declarations and shadows none), so `ScopeEntry` holds a
    /// `u32` row here instead of the binding. Append-only; rows outlive the
    /// entries that name them.
    shadowed_vars: std.ArrayList(VarSlot) = .empty,
    shadowed_arrays: std.ArrayList(ArrayInfo) = .empty,
    /// Every `<block>.<name>` key `heldKey` has composed, so a named block's
    /// local costs one copy, not one per mention (hisimhv_va: ~4.9k
    /// mentions, ~0.9 MB of arena strings before).
    held_keys: std.StringHashMapUnmanaged(void) = .empty,
    /// Every `held_vars` name handed out (`uniqueHeld`), so a clash is one
    /// probe, not a scan of the table per held row.
    held_used: std.StringHashMapUnmanaged(void) = .empty,
    /// Declaration token -> its last `vera_scratch` spec (`scratchSpec`),
    /// built on first use from every attribute in the file.
    scratch_specs: ?std.AutoHashMapUnmanaged(u32, Ast.NatureAttr) = null,
};

/// One `scope_log` row: a declared name and what it shadowed, as rows of
/// `State.shadowed_vars`/`shadowed_arrays` (`none_u32`: nothing).
pub const ScopeEntry = struct { name: []const u8, prev_var: u32, prev_array: u32 };

// Budget: a name and two handles. It was 88 B with the bindings inline.
comptime {
    assert(@sizeOf(ScopeEntry) <= 24);
}

/// Where a `declareVarDecl` sits. §5.3.2 gives a persistent §5.10 slot to a
/// module variable and to a NAMED block's local; an unnamed `begin`'s
/// declaration is neither, and `block_path` is "" for it.
const VarScope = enum { module, local };

const Scratch = enum { off, zero, uninit };

/// §6.8: "An identifier shall be used to declare only one item within a scope.
/// This rule means it is illegal to declare two or more variables which have the
/// same name, or to name a task the same as a variable within the same module, or
/// to give an instance the same name as the name of the net connected to its
/// output."
///
/// Checked across parameters, variables and nets over one scope's declaration
/// lists (not `self.vars`), so shadowing an outer name is not reported. Net
/// against net is allowed (a port direction and its discipline declare one
/// item), and so is a discrete discipline against a variable (§7's `reg out;
/// ddiscrete out;`). A discipline-less net (`wire x;`) clashes with a
/// variable, and so does a continuous one (`electrical p; real p;`): §3.6.2
/// gives a continuous discipline to a net, which is an analog node and never
/// a variable (gnucap's dump_error.6c, "already declared").
///
/// One set per kind, so a scope of n names is O(n): a flattened instance
/// array puts every instance's parameters in the top module's scope.
pub fn checkOneItemPerScope(self: *Lower, params: []const Ast.ParamDecl, vars: []const Ast.VarDecl, nets: []const Ast.NetDecl, ports: []const Ast.Port) Oom!void {
    const Set = std.AutoHashMapUnmanaged(Ast.StrId, void);
    var param_names: Set = .empty;
    defer param_names.deinit(self.arena);
    for (params) |p| {
        if ((try param_names.getOrPut(self.arena, p.name)).found_existing) try dupItem(self, p.main_tok, p.name);
    }
    // A discipline-less net (`wire x;`) clashes with a variable of its name.
    var plain_nets: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty;
    defer plain_nets.deinit(self.arena);
    for (nets) |n| if (n.discipline == .none or rules.isContinuous(self.file, n.discipline)) {
        const gop = try plain_nets.getOrPut(self.arena, n.name);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    };
    // A port's discipline is on the port row; one clash per name.
    for (ports) |p| if (rules.isContinuous(self.file, p.discipline)) {
        const gop = try plain_nets.getOrPut(self.arena, p.name);
        if (!gop.found_existing) gop.value_ptr.* = 1;
    };
    var port_vars: Set = .empty;
    defer port_vars.deinit(self.arena);
    for (self.design.port_vars) |name| try port_vars.put(self.arena, name, {});
    var var_names: Set = .empty;
    defer var_names.deinit(self.arena);
    for (vars) |v| {
        if ((try var_names.getOrPut(self.arena, v.name)).found_existing or param_names.contains(v.name))
            try dupItem(self, v.main_tok, v.name);
        // A child's output-port variable renamed onto this net is the
        // child's declaration, not a second one here (`Design.port_vars`).
        if (port_vars.contains(v.name)) continue;
        for (0..plain_nets.get(v.name) orelse 0) |_| try dupItem(self, v.main_tok, v.name);
    }
    for (nets) |n| {
        if (param_names.contains(n.name)) try dupItem(self, n.main_tok, n.name);
    }
}

/// §3.2 declare and initialize. Verilog-AMS variables start at zero, so a read
/// on a path that never assigned is 0 rather than the SSA builder's `.undef`
/// (which codegen could not emit).
pub fn declareVarDecl(self: *Lower, decl: *const Ast.VarDecl, scope: VarScope) Oom!void {
    assert(self.blockValid(self.cur));
    const name = self.file.str(decl.name);
    const ty = astTy(decl.ty);
    const reg_width: ?u32 = if (decl.storage == .reg) blk: {
        const width = if (decl.packed_range) |range| lower_shape.packedShapeWidth(self, range) orelse {
            try self.err(decl.main_tok, .E0352, "the packed range of `{s}` is not a constant integer range", .{name});
            return;
        } else 1;
        // The limit applies to an analog access, not a declaration. A mixed
        // module can keep wider registers entirely in its digital processes.
        // Retain the folded width so analogRead checks the actual access.
        assert(width != VarSlot.not_reg); // a packed range spans at least one bit
        break :blk width;
    } else null;
    // §5.3.2: "All named block variables are static — that is, an unique
    // location exists for all variables and leaving or entering the block do
    // not affect the values stored in them." The location is (scope, name), so
    // the key `markHeldVars` recorded carries the block path; the empty prefix
    // is module scope, and an UNNAMED block gets no slot because the clause
    // grants one to named blocks only.
    const prefix = if (scope == .module) "" else self.block_path;
    const held_key = if (prefix.len == 0)
        name
    else
        try self.arena.print("{s}{s}", .{ prefix, name });
    // §5.10. A string is held too: it never reaches the residual, but a §9.4
    // task in a later evaluation reads what an event body left in it.
    const why = self.var_state.held_names.get(held_key);
    const d2a = self.var_state.d2a_only.get(held_key) orelse false;
    // VerA's `vera_scratch` (§2.9): no slot, so every evaluation starts from
    // the initializer below. Only a value an `analog initial` or `@(...)` body
    // leaves for a later evaluation's read needs one anyway (E0536).
    var scratch = try scratchOn(self, decl.main_tok);
    if (scratch != .off and why != null and self.var_state.carried.contains(held_key)) {
        try self.err(decl.main_tok, .E0536, "`{s}`", .{name});
        scratch = .off;
    }
    // `"uninit"` starts the variable with no value; an initializer gives it one.
    if (scratch == .uninit and decl.init != .none) {
        try self.err(decl.main_tok, .E0539, "`{s}`", .{name});
        scratch = .zero;
    }
    const hold = (scope == .module or prefix.len != 0) and why != null and scratch == .off;

    if (decl.dims.len != 0) {
        const dims = try lower_shape.dimsBounds(self, decl.dims, decl.main_tok, name) orelse return;
        if (isMemArray(self, decl.name, ty)) {
            const place = try declareMemArray(self, name, dims, ty, !hold);
            self.arrays.getPtr(name).?.mem.?.reg_width = reg_width;
            // Only memory-backed storage has a start to skip: a scalar or a
            // scalarized element is an SSA value whose zero costs nothing,
            // and a zero is one of the values an unwritten read may see.
            self.out.mem_arrays.items[self.arrays.get(name).?.mem.?.id].uninit = scratch == .uninit;
            const elems = try lower_shape.flattenPattern(self, decl.init, dims, false);
            if (hold) {
                // §5.10 the initializer is the `Instance` field's default and
                // nothing else, exactly as for a held scalar: every evaluation
                // starts from what the last accepted one left.
                const inits = try self.arena.alloc(Mir.Value, elems.len);
                for (elems, inits) |elem, *iv| iv.* = if (elem != .none)
                    try self.coerceTo(elem, ty, try lower_expr.lowerExpr(self, elem))
                else
                    zeroOf(ty);
                const id = self.arrays.get(name).?.mem.?.id;
                try self.builder.writeVariable(place, self.cur, try holdArray(self, try qualifyHeld(self, prefix, name), ty, id, inits, place, d2a));
                return;
            }
            // §3.2 an element the pattern does not reach keeps the zero start.
            for (elems, 0..) |elem, k| {
                if (elem == .none) continue;
                const v = try self.coerceTo(elem, ty, try lower_expr.lowerExpr(self, elem));
                try storeElem(self, place, try self.mir.addIntConst(self.arena, @intCast(k)), v);
            }
            return;
        }
        try declareArray(self, name, .{ .dims = dims, .ty = ty });
        // §3.3's own example is `string names[1:3] = '{"first","middle","last"}`:
        // the declaration takes an initializer like a §3.4.4 array parameter.
        // The pattern is positional from the left bound, following the declared
        // direction, one list per dimension (§3.3, §3.4.8).
        const elems = try lower_shape.flattenPattern(self, decl.init, dims, false);
        var sub: [lower_shape.max_stack_dims]i64 = undefined;
        const idx = try lower_shape.subscriptBuf(self, &sub, dims.len);
        for (elems, 0..) |elem, k| {
            lower_shape.shapeSubscripts(dims, k, idx);
            // §3.2.2 arrays are scalarized, so a held array is just one held
            // slot per element — `markHeldVars` records the base name and every
            // element takes a slot, since the index may be a runtime `case`.
            const en = try lower_shape.elemName(self, name, idx);
            const slot = try declareVar(self, en, ty);
            self.vars.getPtr(en).?.reg_width = reg_width orelse VarSlot.not_reg;
            // §3.2 an element the pattern does not reach keeps the zero start.
            const init_val: Mir.Value = if (elem != .none)
                try self.coerceTo(elem, ty, try lower_expr.lowerExpr(self, elem))
            else
                zeroOf(ty);
            try self.builder.writeVariable(slot.place, self.cur, if (hold)
                try holdSlot(self, try qualifyHeld(self, prefix, en), ty, init_val, slot.place, why.?, d2a)
            else
                init_val);
        }
        return;
    }

    // IEEE 1364-2005 §5.4: a `reg` past 32 bits that the analog context
    // computes holds every bit of it (`lower_wide`); one it never assigns
    // keeps its literal for the whole analysis (`Lower.reg_consts`).
    const wide_w: ?u32 = if (reg_width) |w| (if (w > 32 and !literalReg(self, decl, scope)) w else null) else null;
    const vty: Ty = if (wide_w != null) .wide else ty;
    // §7.3.6.4 the mixed runner copies a held 64-bit integer to the digital
    // engine (`tb/runner.zig` `a2d_ports`), which a wide `reg` is not.
    if (wide_w != null and scope == .module and self.out.discrete_reads.contains(name))
        try self.err(decl.main_tok, .E0329, "a digital process reads `{s}`, a `reg` wider than 32 bits the analog context computes; its bits do not reach the digital engine", .{name});
    const slot = try declareVar(self, name, vty);
    self.vars.getPtr(name).?.reg_width = reg_width orelse VarSlot.not_reg;
    self.vars.getPtr(name).?.reg_signed = decl.storage == .reg and decl.is_signed;
    if (decl.storage == .reg) if (decl.packed_range) |range| if (lower_constfold.constEval(self, range.msb)) |m| if (lower_constfold.constEval(self, range.lsb)) |l| {
        const right = l.asIntExact() orelse 0;
        try self.reg_ranges.put(self.arena, name, .{ .right = right, .asc = (m.asIntExact() orelse 0) < right, .width = reg_width.?, .signed = decl.is_signed });
    };
    const init_val: Mir.Value = if (wide_w) |w|
        (if (decl.init == .none) try lower_wide.zero(self, w) else try lower_wide.rhs(self, w, decl.init))
    else if (decl.init == .none)
        zeroOf(ty)
    else if (reg_width != null and reg_width.? > 32 and self.file.exprs.tag(decl.init) == .logic_literal)
        // §7.3.1 a wide `reg` holding its literal (`Lower.reg_consts`): the
        // slot is its low 64 bits; a select above them reads the literal.
        try self.mir.addIntConst(self.arena, lower_wide.literalLow64(self, decl.init))
    else
        try self.coerceTo(decl.init, ty, try lower_expr.lowerExpr(self, decl.init));
    try self.builder.writeVariable(slot.place, self.cur, if (hold) blk: {
        const seed = try holdSlot(self, held_key, vty, init_val, slot.place, why.?, d2a);
        if (wide_w) |w| self.out.held_vars.items[self.out.held_vars.items.len - 1].width = w;
        break :blk seed;
    } else init_val);
    // §7.3.6.1 "An event occurs whenever a value is assigned to the variable,
    // regardless of whether the variable changes value or not": the host
    // tells an assignment from no assignment by this count.
    if (hold and why.? == .event and prefix.len == 0 and self.out.discrete_reads.contains(name))
        try self.var_state.assign_counts.put(self.arena, slot.place, try hiddenHeldInt(self, try self.arena.print("{s}{s}", .{ Lower.HeldVar.assign_count_prefix, name })));
    try lower_noise_src.noteVarNoise(self, name, decl.init);
}

/// §7.3.1 a module `reg` the analog context never assigns, whose initializer
/// is a literal or absent: it holds that literal for the whole analysis
/// (`Lower.reg_consts`, filled after the declaration by `lowerModule`).
pub fn literalReg(self: *const Lower, decl: *const Ast.VarDecl, scope: VarScope) bool {
    if (scope != .module or self.analog_writes.contains(decl.name)) return false;
    if (decl.init == .none) return true;
    return switch (self.file.exprs.tag(decl.init)) {
        .int_literal, .logic_literal => true,
        else => false, // else: any other initializer is computed (`lower_wide.rhs`)
    };
}

/// §7.3.6.1 counts one assignment of `place`, when it has a count.
pub fn countAssign(self: *Lower, place: Ssa.Place) Oom!void {
    assert(self.blockValid(self.cur));
    const c = self.var_state.assign_counts.get(place) orelse return;
    const n = try self.builder.readVariable(c.place, self.cur);
    try self.builder.writeVariable(c.place, self.cur, try self.emit(.iadd, &.{ n, try self.mir.addIntConst(self.arena, 1) }));
}

/// A compiler-owned retained integer discovered during expression lowering.
/// Seed it in entry so even a branch that skips its first use has a value.
pub fn hiddenHeldInt(self: *Lower, name: []const u8) Oom!VarSlot {
    assert(self.blockValid(self.cur));
    const place = self.builder.newPlace();
    const at = self.cur;
    self.cur = .entry;
    defer self.cur = at;
    const seed = try holdSlot(self, name, .integer, .zero, place, .retained, false);
    try self.builder.writeVariable(place, .entry, seed);
    return .{ .place = place, .ty = .integer };
}

/// Pops the scope log back to `mark`, restoring each variable and array binding
/// the scope shadowed. Asserts that `mark` is a length the log has had.
pub fn closeScope(self: *Lower, mark: usize) void {
    assert(mark <= self.scope_log.items.len);
    while (self.scope_log.items.len > mark) {
        const e = self.scope_log.pop().?;
        if (e.prev_var != none_u32) {
            self.vars.putAssumeCapacity(e.name, self.var_state.shadowed_vars.items[e.prev_var]);
        } else {
            _ = self.vars.remove(e.name);
        }
        if (e.prev_array != none_u32) {
            self.arrays.putAssumeCapacity(e.name, self.var_state.shadowed_arrays.items[e.prev_array]);
        } else {
            _ = self.arrays.remove(e.name);
        }
    }
}

/// Binds `name` to an array, remembering what it shadowed (§5.3.2).
pub fn declareArray(self: *Lower, name: []const u8, info: ArrayInfo) Oom!void {
    try shadowName(self, name);
    try self.arrays.put(self.arena, name, info);
}

/// Bind `name` to a fresh SSA place, remembering what it shadowed (§5.3.2).
pub fn declareVar(self: *Lower, name: []const u8, ty: Ty) Oom!VarSlot {
    const slot: VarSlot = .{ .place = self.builder.newPlace(), .ty = ty };
    try shadowName(self, name);
    try self.vars.put(self.arena, name, slot);
    return slot;
}

/// §3.2.2 is `name` a memory-backed array? A string array never is: a string
/// has no runtime storage (§3.3), so its runtime reads stay `$idx$str`.
pub fn isMemArray(self: *const Lower, name: Ast.StrId, ty: Ty) bool {
    return ty != .string and self.var_state.mem_names.contains(name);
}

/// §3.2.2 declare `name` as ONE storage of `shapeCells(dims)` elements and
/// return the place that holds its current version — when `zero`, a fresh one
/// with every element zero (§3.2); otherwise the caller writes the first.
pub fn declareMemArray(self: *Lower, name: []const u8, dims: []const lower_shape.Bounds, ty: Ty, zero: bool) Oom!Ssa.Place {
    assert(self.blockValid(self.cur));
    const id: u32 = @intCast(self.out.mem_arrays.items.len);
    try self.out.mem_arrays.append(self.arena, .{ .name = name, .len = @intCast(lower_shape.shapeCells(dims)), .ty = ty });
    const place = self.builder.newPlace();
    try declareArray(self, name, .{ .dims = dims, .ty = ty, .mem = .{ .place = place, .id = id } });
    if (zero) try self.builder.writeVariable(place, self.cur, try self.mir.emitAnew(self.arena, self.cur, id));
    return place;
}

/// §3.2.2 `a[index] = v` on a memory-backed array: the next version.
pub fn storeElem(self: *Lower, place: Ssa.Place, index: Mir.Value, v: Mir.Value) Oom!void {
    assert(self.valueValid(index));
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    const cur = try self.builder.readVariable(place, self.cur);
    try self.builder.writeVariable(place, self.cur, try self.emit(.store, &.{ cur, index, v }));
}

/// §3.2.2 element `index` of a memory-backed array's current version.
pub fn loadElem(self: *Lower, mem: ArrayInfo.Mem, ty: Ty, index: Mir.Value) Oom!Mir.Value {
    assert(self.valueValid(index));
    assert(self.blockValid(self.cur));
    const cur = try self.builder.readVariable(mem.place, self.cur);
    const value = try self.emit(if (ty == .integer) .iload else .fload, &.{ cur, index });
    return analogRead(self, value, mem.reg_width);
}

/// §7.3.1: the analog value of a discrete bit grouping is a nonnegative
/// 32-bit integer. The source width controls zero extension, not arithmetic.
pub fn analogRead(self: *Lower, value: Mir.Value, width: ?u32) Oom!Mir.Value {
    assert(self.valueValid(value));
    assert(self.blockValid(self.cur));
    const w = width orelse return value;
    if (w > 31) {
        try self.err(self.mir.cur_tok, .E0222, "this analog access reads {d} bits", .{w});
        return .undef;
    }
    const mask = (@as(u32, 1) << @intCast(w)) - 1;
    return self.emit(.bitand, &.{ value, try self.mir.addIntConst(self.arena, mask) });
}

/// §3.2.2 constant-subscript element write for either representation: the
/// element's own place, or a store into the array's storage.
pub fn writeElem(self: *Lower, name: []const u8, info: ArrayInfo, idx: []const i64, v: Mir.Value) Oom!void {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    if (info.mem) |m| return storeElem(self, m.place, try self.mir.addIntConst(self.arena, lower_shape.flatIndex(info.dims, idx)), v);
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const slot = self.vars.get(try lower_shape.elemKey(self, &key_buf, name, idx)) orelse return;
    try self.builder.writeVariable(slot.place, self.cur, v);
}

/// §7.2.2 every name an `analog` or `analog initial` block of `module`
/// writes (an assignment target, an output actual, a `$random` seed), as
/// `Ast.SourceFile.stmtWrites` finds them.
pub fn analogWrites(self: *Lower, module: *const Ast.ModuleDecl) Oom!std.AutoHashMapUnmanaged(Ast.StrId, void) {
    assert(module.name != .none);
    var out: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    const Walk = struct {
        l: *Lower,
        funcs: []const Ast.FuncDecl,
        writes: *std.ArrayList(Ast.ExprId),
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            if (s == .none) return;
            try w.l.file.stmtWrites(w.funcs, s, w.l.arena, w.writes);
            try w.l.file.stmtEdges(s, w);
        }
    };
    const walk: Walk = .{ .l = self, .funcs = module.functions, .writes = &writes };
    for (module.analog) |blk| try walk.stmt(blk.body);
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t != .none) try out.put(self.arena, self.file.exprs.strOf(t), {});
    }
    return out;
}

/// §2.9 E0535: every `vera_scratch` in `module` decorates a variable
/// declaration (§3.2), the only item with a value an evaluation assigns.
pub fn checkScratchOwners(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.file.str(a.name), "vera_scratch")) continue;
        const on_var = outer: for (self.file.attributes.items) |b| {
            if (b.owner.kind != .declaration) continue;
            for (b.specs) |s| if (s.main_tok == a.main_tok and isVarTok(self, module, b.owner.tok)) break :outer true;
        } else false;
        if (!on_var) try self.err(a.main_tok, .E0535, "", .{});
    }
    // E0537: VAMS §7.2.2 gives a variable a discrete process (an `initial`
    // or `always` block, or a task, A.2.7) assigns to the discrete context,
    // where IEEE 1364-2005 §4.2.2 says it "shall retain [its] value until the
    // next assignment". The digital kernel owns that storage, so the analog
    // evaluation this attribute is about never resets it.
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    for (module.discrete) |blk| try lower_context.collectWrites(self, blk.body, &writes);
    for (module.tasks) |t| try lower_context.collectWrites(self, t.body, &writes);
    if (writes.items.len == 0) return;
    var digital: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    for (writes.items) |w| try digital.put(self.arena, self.file.exprs.strOf(w), {});
    for (module.vars) |v| try refuseDigitalScratch(self, &digital, v);
    for (module.tasks) |t| for (t.vars) |v| try refuseDigitalScratch(self, &digital, v);
    // A named block's locals inside a discrete process are the process's.
    const Blocks = struct {
        l: *Lower,
        digital: *const std.AutoHashMapUnmanaged(Ast.StrId, void),
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            if (s == .none) return;
            if (w.l.file.stmt(s) == .block) for (w.l.file.stmt(s).block.vars) |v| try refuseDigitalScratch(w.l, w.digital, v);
            try w.l.file.stmtEdges(s, w);
        }
    };
    const walk: Blocks = .{ .l = self, .digital = &digital };
    for (module.discrete) |blk| try walk.stmt(blk.body);
    for (module.tasks) |t| try walk.stmt(t.body);
}

/// Returns a variable's §3.2 zero start; a string's is `.undef`.
pub fn zeroOf(ty: Ty) Mir.Value {
    return switch (ty) {
        .real => .f_zero,
        .integer => .zero,
        .string => .undef,
        .wide => unreachable, // its zero has a width (`lower_wide.zero`)
    };
}

// ---- private ----

fn dupItem(self: *Lower, tok: u32, name: Ast.StrId) Oom!void {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    var b = self.errWith(tok, .E0362);
    b.msg("`{s}`", .{self.file.str(name)});
    b.note("§6.8: one identifier declares one item in a scope — the earlier declaration is unreachable", .{});
    try b.emit();
}

/// VerA's `vera_scratch` (§2.9) on the variable declared at token `tok`: the
/// last spec wins; §2.9's default 1 when it has no value, otherwise a
/// constant that folds without the model card, since it decides whether the
/// device keeps a slot (E0534, and the variable is held where observable).
/// The string `"uninit"` drops the zero start too; any other string is E0538.
fn scratchOn(self: *Lower, tok: u32) Oom!Scratch {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    const a = try scratchSpec(self, tok) orelse return .off;
    if (a.value == .none) return .zero;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0534, "", .{});
        return .off;
    };
    return scratchMode(c) orelse {
        try self.err(a.main_tok, .E0538, "`\"{s}\"`", .{c.str});
        return .off;
    };
}

/// The mode a folded `vera_scratch` value names; null for a string other than
/// `"uninit"` (E0538).
fn scratchMode(c: Const) ?Scratch {
    return switch (c) {
        .str => |s| if (std.mem.eql(u8, s, "uninit")) .uninit else null,
        .int, .real => if (c.isTrue()) .zero else .off,
    };
}

/// The `Instance` field name of a held slot carries the block path too, because
/// codegen derives one struct field per `held_vars` entry from it and two
/// blocks may spell a local the same way (§5.3.2's whole point).
fn qualifyHeld(self: *Lower, prefix: []const u8, name: []const u8) Oom![]const u8 {
    if (prefix.len == 0) return name;
    return self.arena.print("{s}{s}", .{ prefix, name });
}

/// Codegen makes one `Instance` field per `held_vars` entry out of its name, so
/// the name has to be unique. It is — until a §6.6.1 unrolled `for` lowers the
/// SAME named block twice, which is two executions of one source declaration
/// and so, by §5.3.2, two locations that happen to share a path.
fn uniqueHeld(self: *Lower, name: []const u8, idx: u32) Oom![]const u8 {
    const used = &self.var_state.held_used;
    const unique = if (used.contains(name)) try self.arena.print("{s}.{d}", .{ name, idx }) else name;
    try used.put(self.arena, unique, {});
    return unique;
}

/// §5.10. Give one event-assigned variable its persistent `Instance` slot and
/// return the Value that READS that slot.
///
/// The read replaces the declared initializer AT THE DECLARATION, which is the
/// whole reason the decision is made here and not at the assignment that
/// reveals it: a read of the variable that lexically precedes the `@(...)` must
/// also see the retained value, and by the time lowering reaches that
/// assignment the earlier read has already been resolved against the
/// initializer and memoized. Patching the entry def afterwards would leave it
/// stale.
///
/// `$held_real` / `$held_int` are synthetic callees with no op kind
/// (`callee.opKind`), so they create no unit and renumber no `Instance` state.
/// The single argument is the index into `held_vars`, which is how codegen
/// recovers the field.
fn holdSlot(self: *Lower, name: []const u8, ty: Ty, init_val: Mir.Value, place: Ssa.Place, why: Lower.HeldVar.Why, d2a: bool) Oom!Mir.Value {
    // Emitted into the DECLARATION's block — `.entry`, unless the initializer
    // itself opened a diamond (§4.2.7 `&&`/`||` short-circuit), in which case it
    // is that diamond's join. Either way it dominates every statement of the
    // module, which is all the seed has to do.
    assert(self.held_places.items.len == self.out.held_vars.items.len); // one place per held row
    const idx: i64 = @intCast(self.out.held_vars.items.len);
    const seed = try self.call(switch (ty) {
        .integer => "$held_int",
        .real => "$held_real",
        .string => "$held_str",
        .wide => "$held_wide",
    }, &.{try self.mir.addIntConst(self.arena, idx)});
    try self.out.held_vars.append(self.arena, .{
        .name = try uniqueHeld(self, name, @intCast(idx)),
        .ty = ty,
        .init = init_val,
        .seed = seed,
        .why = why,
        .d2a = d2a,
    });
    try self.held_places.append(self.arena, place);
    assert(self.held_places.items.len == self.out.held_vars.items.len);
    return seed;
}

/// §5.10 `holdSlot` for a memory-backed array: ONE held row whose seed is the
/// array's `anew` (which codegen fills from the `Instance` field) and whose
/// final value is the array version the block ends with.
fn holdArray(self: *Lower, name: []const u8, ty: Ty, id: u32, inits: []const Mir.Value, place: Ssa.Place, d2a: bool) Oom!Mir.Value {
    assert(self.held_places.items.len == self.out.held_vars.items.len); // one place per held row
    assert(id < self.out.mem_arrays.items.len);
    const idx: u32 = @intCast(self.out.held_vars.items.len);
    const seed = try self.mir.emitAnew(self.arena, self.cur, id);
    self.out.mem_arrays.items[id].held = idx;
    try self.out.held_vars.append(self.arena, .{
        .name = try uniqueHeld(self, name, idx),
        .ty = ty,
        .init = zeroOf(ty),
        .seed = seed,
        .array = id,
        .inits = inits,
        .d2a = d2a,
    });
    try self.held_places.append(self.arena, place);
    assert(self.held_places.items.len == self.out.held_vars.items.len);
    return seed;
}

fn shadowName(self: *Lower, name: []const u8) Oom!void {
    const st = &self.var_state;
    var e: ScopeEntry = .{ .name = name, .prev_var = none_u32, .prev_array = none_u32 };
    if (self.vars.get(name)) |p| {
        e.prev_var = @intCast(st.shadowed_vars.items.len);
        try st.shadowed_vars.append(self.arena, p);
    }
    if (self.arrays.get(name)) |a| {
        e.prev_array = @intCast(st.shadowed_arrays.items.len);
        try st.shadowed_arrays.append(self.arena, a);
    }
    try self.scope_log.append(self.arena, e);
    _ = self.vars.remove(name);
    _ = self.arrays.remove(name);
}

/// `vera_scratch` on `v`, when on, and a discrete process writes `v` (E0537).
/// A value that does not fold (E0534) or names no mode (E0538) is reported at
/// the declaration.
fn refuseDigitalScratch(self: *Lower, digital: *const std.AutoHashMapUnmanaged(Ast.StrId, void), v: Ast.VarDecl) Oom!void {
    if (!digital.contains(v.name)) return;
    const a = try scratchSpec(self, v.main_tok) orelse return;
    if (a.value != .none) {
        const c = lower_constfold.foldExpr(self, a.value, false) orelse return;
        if ((scratchMode(c) orelse return) == .off) return;
    }
    try self.err(a.main_tok, .E0537, "`{s}`", .{self.file.str(v.name)});
}

/// The last `vera_scratch` spec on the declaration at token `tok` (§2.9).
fn scratchSpec(self: *Lower, tok: u32) Oom!?Ast.NatureAttr {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    const specs = &self.var_state.scratch_specs;
    if (specs.* == null) {
        // Built once: a scan of every attribute per declaration was 2% of a
        // large compact model's lint.
        var map: std.AutoHashMapUnmanaged(u32, Ast.NatureAttr) = .empty;
        for (self.file.attributes.items) |b| if (b.owner.kind == .declaration) for (b.specs) |s| {
            if (std.mem.eql(u8, self.file.str(s.name), "vera_scratch")) try map.put(self.arena, b.owner.tok, s);
        };
        specs.* = map;
    }
    return specs.*.?.get(tok);
}

fn isVarTok(self: *const Lower, module: *const Ast.ModuleDecl, tok: u32) bool {
    assert(module.name != .none);
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    for (module.vars) |v| if (v.main_tok == tok) return true;
    for (module.functions) |f| for (f.vars) |v| if (v.main_tok == tok) return true;
    for (module.tasks) |t| for (t.vars) |v| if (v.main_tok == tok) return true;
    var blocks = self.file.seqBlocks();
    while (blocks.next()) |b| for (b.vars) |v| if (v.main_tok == tok) return true;
    return false;
}

test zeroOf {
    // §3.2 "Real variables are initialized to zero (0)", an integer too; a
    // string has no numeric zero.
    try std.testing.expectEqual(Mir.Value.f_zero, zeroOf(.real));
    try std.testing.expectEqual(Mir.Value.zero, zeroOf(.integer));
    try std.testing.expectEqual(Mir.Value.undef, zeroOf(.string));
}

test uniqueHeld {
    // One `Instance` field per held row: a name taken is suffixed by its row.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator, "module m; endmodule");
    defer h.deinit();
    try std.testing.expectEqualStrings("x", try uniqueHeld(&h.low, "x", 0));
    try std.testing.expectEqualStrings("y", try uniqueHeld(&h.low, "y", 1));
    try std.testing.expectEqualStrings("x.2", try uniqueHeld(&h.low, "x", 2));
    try std.testing.expectEqualStrings("x.3", try uniqueHeld(&h.low, "x", 3));
}

test "checkOneItemPerScope: §6.8 one identifier declares one item in a scope (E0362)" {
    try Lower.expectBodyVerdict("  real x;\n  integer x;", "", .E0362);
    try Lower.expectBodyVerdict("  parameter real x = 1.0;\n  real x;", "", .E0362);
    // A continuous net is a node, not a variable; a discrete one may be both.
    try Lower.expectBodyVerdict("  electrical x;\n  real x;", "", .E0362);
    try Lower.expectBodyVerdict("  ddiscrete x;\n  reg x;", "", null);
    // A named block is a scope of its own (§5.3.2): shadowing is no clash.
    try Lower.expectBodyVerdict("  real x;", "    begin : b\n      real x;\n      x = 1.0;\n    end", null);
}

test "closeScope: §5.3.2 a block's declaration shadows for the block, and its name stays reachable" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer x;
        \\  analog begin
        \\    begin : b
        \\      real x;
        \\      x = 1.5;
        \\    end
        \\    x = 2;
        \\    I(p) <+ x * V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    // The block closed: `x` is the module's integer again, and the local is
    // §5.3.2's `b.x`, "accessed outside the scope in which [it is] declared".
    try std.testing.expectEqual(Ty.integer, h.low.vars.get("x").?.ty);
    try std.testing.expectEqual(Ty.real, h.low.vars.get("b.x").?.ty);
    try std.testing.expect(h.low.block_locals.contains("b.x"));
}

test "declareVarDecl: §2.9 vera_scratch values and owners" {
    // Any string but "uninit" (E0538); "uninit" with an initializer (E0539);
    // on anything but a variable (E0535).
    try Lower.expectBodyVerdict("  (* vera_scratch *) real s;", "    s = 1.0;", null);
    try Lower.expectBodyVerdict("  (* vera_scratch = \"nope\" *) real s;", "    s = 1.0;", .E0538);
    try Lower.expectBodyVerdict("  (* vera_scratch = \"uninit\" *) real s = 1.0;", "", .E0539);
    // The last spec on a declaration wins.
    try Lower.expectBodyVerdict("  (* vera_scratch = \"nope\", vera_scratch *) real s;", "    s = 1.0;", null);
    try Lower.expectBodyVerdict("  (* vera_scratch, vera_scratch = \"nope\" *) real s;", "    s = 1.0;", .E0538);
    try Lower.expectBodyVerdict("  (* vera_scratch *) parameter real g = 1.0;", "", .E0535);
    // §7.3.1 a `reg`'s packed range is a constant (E0352).
    try Lower.expectBodyVerdict("  integer w;\n  reg [w:0] r;", "", .E0352);
}
