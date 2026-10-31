const std = @import("std");
const assert = std.debug.assert;
const discipline_rules = @import("elab").discipline_rules;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const naming = @import("ir").names;
const Lower = @import("Lower.zig");
const lower_discrete_mark = @import("discrete_mark.zig");
const lower_constfold = @import("constfold.zig");
const lower_param = @import("param.zig");
const lower_shape = @import("shape.zig");
const lower_expr_select = @import("expr_select.zig");
const lower_expr_case = @import("expr_case.zig");
const lower_context = @import("context.zig");
const lower_node_ref = @import("node_ref.zig");
const Reads = lower_discrete_mark.Reads;
const EventRefs = lower_context.EventRefs;
const Oom = Lower.Oom;

/// Declares the analog block's view of a mixed module's digital half
/// (§7.3.1, §7.3.6.5, §8.5). Every variable a discrete process writes and every
/// net a continuous assignment drives is digital-owned (§7.2.2), and the analog
/// block reads its value at "the greatest digital time tick which is less than
/// or equal to the analog time" (§7.3.6.5). So each one the analog block reads
/// becomes a host-written input: a hidden §3.4 parameter of the same name (a
/// `Model` field the mixed-signal host writes before every solve), typed per
/// Table 7-1. No-op for a module that is not mixed.
///
/// Must run before the ports and nets are interned, so a digital-owned net
/// never becomes an analog node.
pub fn declareDiscreteInputs(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    // ponytail: a Model field is per model, and a discrete input is per
    // instance. Exact for the testbench (one instance), wrong for a host that
    // instantiates one mixed device twice; the right home is an `Instance`
    // field, which is codegen's to emit.
    if (!lower_context.isMixed(self.file, module)) return;
    self.out.mixed_signal = true;
    const ex = &self.file.exprs;
    for (module.nets) |n| if (n.kind == .wreal) try lower_context.checkWrealDrivers(self, module, n.name, n.init != .none);
    for (module.ports) |p| if (p.kind == .wreal) try lower_context.checkWrealDrivers(self, module, p.name, false);
    var owned: std.ArrayList(Ast.ExprId) = .empty;
    for (module.assigns) |a| {
        const t = self.file.lvalueBase(a.target);
        // IEEE 1364-2005 §6.1 (via VAMS §1.1): A.6.1's `net_assignment`
        // drives a `net_lvalue` — a variable has no driver to add. A port
        // with no net or variable declaration is a net: §12.3.3 "If a port
        // declaration does not include a net or variable type, then the port
        // can be again declared in a net or variable declaration", and
        // undeclared it is an implicit net of the default net type.
        if (t == .none or (lower_context.netOf(module, ex.strOf(t)) == null and !lower_context.isNetName(module, ex.strOf(t)))) {
            try self.err(a.main_tok, .E0438, "", .{});
            continue;
        }
        const discipline = if (lower_context.netOf(module, ex.strOf(t))) |n| n.discipline else for (module.ports) |p| {
            if (p.name == ex.strOf(t)) break p.discipline;
        } else unreachable; // `isNetName` found it among the nets or the ports
        // The declaration kind decided E0438; the domain decides this one.
        // §7.2: "only digital blocks and primitives can drive a discrete net",
        // and §7.3: "Write operations of nets ... are only allowed from the
        // context of their domain" — and a continuous assignment is the
        // discrete context. A `ddiscrete` net (§3.6.2.2 `domain discrete`) is
        // a net exactly as `wire` is, and legal here.
        if (discipline_rules.isContinuous(self.file, discipline)) {
            try self.err(a.main_tok, .E0435, "`{s}` is driven by a continuous assignment", .{self.file.str(ex.strOf(t))});
            continue;
        }
        try owned.append(self.arena, t);
    }
    for (module.discrete) |blk| try lower_context.collectWrites(self, blk.body, &owned);
    // A task (A.2.7) is enabled only from the discrete context, so what its
    // body writes is digital-owned too.
    // ponytail: every task's body, enabled or not, and a formal or local that
    // shadows a module variable counts as that variable; the output actuals
    // of an enable are not collected. Follow the enables when a source needs it.
    for (module.tasks) |t| try lower_context.collectWrites(self, t.body, &owned);
    // §7.2 "only digital blocks and primitives can drive a discrete net": a
    // discrete net on a switch terminal takes its value from the switch-level
    // resolution of its whole network (§8.5.3.5), which the kernel computes.
    for (module.switches) |sw| for (sw.terms) |t| if (lower_context.discreteNet(self.file, module, t)) |id| try owned.append(self.arena, id);
    // §7.3.1 "Read operations of nets ... are allowed from both contexts": a
    // discrete net the analog block reads holds the kernel's value, z when
    // nothing drives it.
    for (module.analog) |blk| _ = try lower_context.analogDiscreteNets(self.file, module, blk.body, .{ .a = self.arena, .list = &owned });
    var owned_names: std.ArrayList(struct { name: Ast.StrId, tok: u32 }) = .empty;
    for (owned.items) |t| try owned_names.append(self.arena, .{ .name = ex.strOf(t), .tok = ex.mainTok(t) });
    // §3.7 "If no driver is connected to a wreal net, its value shall be zero
    // (0.0)": a wreal is digital-owned whether or not anything drives it.
    for (module.nets) |n| if (n.kind == .wreal) try owned_names.append(self.arena, .{ .name = n.name, .tok = n.main_tok });
    // What a digital event term in an analog event control may watch (§7.3.4):
    // a digital-owned value, or a named event the digital context triggers
    // (§5.10.4 / §5.10.5).
    var digital: std.StringHashMapUnmanaged(void) = .empty;
    for (owned_names.items) |t| try digital.put(self.arena, self.file.str(t.name), {});
    var trig: EventRefs = .{ .l = self, .module = module, .triggers_only = true };
    for (module.discrete) |blk| try trig.stmt(blk.body);
    for (trig.names.keys()) |name| try digital.put(self.arena, name, {});
    // Only what the analog block READS crosses: an owned value it never names
    // is the digital engine's alone, and must not make a solve fail on an x
    // (§7.3.2) that nothing analog ever sees.
    var reads: Reads = .{ .l = self, .digital = &digital };
    for (module.analog) |blk| try reads.stmt(blk.body);
    // §7.3.6.4 / §7.3.1, A2D: "Read operations of nets and variables in both
    // domains are allowed from both contexts", so a module variable a digital
    // expression reads and no digital context assigns is the analog block's.
    const DReads = struct {
        l: *Lower,
        module: *const Ast.ModuleDecl,
        digital: *const std.StringHashMapUnmanaged(void),
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            if (e == .none) return;
            const fx = &w.l.file.exprs;
            if (fx.tag(e) == .ident) for (w.module.params) |p| {
                if (p.name != fx.strOf(e)) continue;
                const name = w.l.file.str(p.name);
                if (!w.l.out.discrete_params.contains(name)) {
                    try w.l.out.discrete_params.put(w.l.arena, name, fx.mainTok(e));
                    // §6.3.4 a later parameter can depend on this one, even
                    // when its name never appears directly in a process.
                    try w.expr(p.default, .read);
                }
                break;
            };
            if (fx.tag(e) == .ident) for (w.module.vars) |v| {
                const name = w.l.file.str(v.name);
                if (v.name != fx.strOf(e) or w.digital.contains(name)) continue;
                if (!w.l.out.discrete_reads.contains(name)) try w.l.out.discrete_reads.put(w.l.arena, name, fx.mainTok(e));
                break;
            };
            var buf: [3]Ast.ExprId = undefined;
            for (fx.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            if (s != .none) try w.l.file.stmtEdges(s, w);
        }
    };
    const dreads: DReads = .{ .l = self, .module = module, .digital = &digital };
    for (module.assigns) |a| try dreads.expr(a.value, .read);
    for (module.discrete) |blk| try dreads.stmt(blk.body);
    // §8.5 each explicit D2A term is a host-set flag.
    for (reads.sites.items, 0..) |site, k| {
        const param = try self.arena.print("__d2a{d}", .{k});
        try self.out.discrete_events.put(self.arena, site.term, .{ .name = site.name, .edge = site.edge, .param = param });
        try lower_param.addParam(self, param, .integer, try self.mir.addIntConst(self.arena, 0), .{ .int = 0 }, &.{}, false, ex.mainTok(site.term));
    }
    for (owned_names.items) |t| {
        const name = self.file.str(t.name);
        if (!reads.guarded.contains(name) and !reads.names.contains(name)) continue;
        const ty: Ast.Type = for (module.vars) |v| {
            if (v.name == t.name) break v.ty;
        } else if (lower_context.netOf(module, t.name)) |n| (if (n.kind == .wreal) .real else .integer) else for (module.ports) |p| {
            if (p.name == t.name) break if (p.kind == .wreal) .real else .integer;
        } else continue; // an undeclared name is §6.8's, reported elsewhere
        // VAMS Table 7-1: a bit grouping, a net and an `integer` read as an
        // integer, a `real` "with no conversion".
        const real = switch (ty) {
            .integer => false,
            .real => true,
            else => { // else: Table 7-1 has no row for any other type
                try self.err(t.tok, .E0437, "`{s}` is a digital `{t}`, and Table 7-1 converts only integer, bit and real values", .{ name, ty });
                continue;
            },
        };
        const zero = if (real) try self.mir.addFloatConst(self.arena, 0) else try self.mir.addIntConst(self.arena, 0);
        const folded: Lower.Const = if (real) .{ .real = 0 } else .{ .int = 0 };
        if (reads.guarded.contains(name) and !self.out.discrete_snaps.contains(name)) {
            // §8.5.3.6: the guarded read's region-1b snapshot.
            try self.out.discrete_snaps.put(self.arena, name, t.tok);
            const snap = try naming.snapField(self.arena, name);
            try lower_param.addParam(self, snap, ty, zero, folded, &.{}, false, t.tok);
        }
        if (self.out.discrete_inputs.contains(name) or !reads.names.contains(name)) continue;
        // §7.3.1 Table 7-1's `reg [0:9] r[0:7]`: an element of a digital
        // array reads as an integer, so each element is an input of its own,
        // `name[k]` (`lower_expr_select.lowerIndex` selects among them).
        const dims: []const Ast.Dim = for (module.vars) |v| {
            if (v.name == t.name) break v.dims;
        } else &.{};
        if (dims.len != 0) {
            if (self.discrete_arrays.contains(name)) continue; // written more than once
            try declareDiscreteArray(self, name, dims, ty, zero, folded, t.tok, reads.guarded.contains(name));
            continue;
        }
        try self.out.discrete_inputs.put(self.arena, name, t.tok);
        try lower_param.addParam(self, name, ty, zero, folded, &.{}, false, t.tok);
        // §7.3.1 a `reg` input: its packed range, for a select's bits, and
        // past 32 bits one more `Model` field per 32-bit word, so a select
        // anywhere in it reads exact bits (`lower_expr_select.lowerRegSelect`).
        if (!real) for (module.vars) |v| {
            if (v.name != t.name or v.storage != .reg or v.dims.len != 0) continue;
            const range = v.packed_range orelse break;
            const width = lower_shape.packedShapeWidth(self, range) orelse break;
            const m = lower_constfold.constEval(self, range.msb) orelse break;
            const l = lower_constfold.constEval(self, range.lsb) orelse break;
            const right = l.asIntExact() orelse 0;
            try self.reg_ranges.put(self.arena, name, .{ .right = right, .asc = (m.asIntExact() orelse 0) < right, .width = width, .signed = v.is_signed });
            if (width <= 32) break;
            const n_words: u32 = (width + 31) / 32;
            try self.out.discrete_words.put(self.arena, name, n_words);
            for (1..n_words) |k| try lower_param.addParam(self, try naming.wordField(self.arena, name, k), .integer, zero, folded, &.{}, false, t.tok);
            break;
        };
        if (!real and reads.fourStateOnly(name)) {
            // §7.3.2 the unknown plane, for `===`/`!==`/`case` (`lower_expr_case.fourState`).
            // A name also read any other way keeps the x/z error at every
            // solve (the runner's `mixedInput`), and compares two-state.
            try self.out.discrete_xz.put(self.arena, name, {});
            const xz = try naming.xzField(self.arena, name);
            try lower_param.addParam(self, xz, .integer, try self.mir.addIntConst(self.arena, 0), .{ .int = 0 }, &.{}, false, t.tok);
        }
    }
}

/// The most elements a digital array the analog block reads may have: each
/// is a `Model` field the mixed runner copies at every digital tick.
const max_discrete_elems = 4096;

/// §7.3.1 one input per element of the digital array `name` (one dimension,
/// constant bounds), `name[k]` for each declared `k`, read as its scalar
/// inputs are (`Lower.discrete_arrays`). A guarded read's snapshot and a
/// second dimension are refused (E0437).
fn declareDiscreteArray(self: *Lower, name: []const u8, dims: []const Ast.Dim, ty: Ast.Type, zero: Mir.Value, folded: Lower.Const, tok: u32, guarded: bool) Oom!void {
    assert(name.len != 0);
    assert(self.valueValid(zero));
    if (dims.len != 1 or guarded) {
        try self.err(tok, .E0437, "`{s}` is a digital array the analog block reads {s}; VerA reads one dimension, outside an explicit D2A event's body", .{ name, if (guarded) "in an explicit D2A event's body" else "with more than one dimension" });
        return;
    }
    const range = try lower_node_ref.foldDim(self, dims[0], tok) orelse return;
    const lo = @min(range.msb, range.lsb);
    const hi = @max(range.msb, range.lsb);
    if (hi - lo + 1 > max_discrete_elems) {
        try self.err(tok, .E0437, "`{s}` is a digital array of {d} elements the analog block reads; VerA copies at most {d}", .{ name, hi - lo + 1, max_discrete_elems });
        return;
    }
    var k = lo;
    while (k <= hi) : (k += 1) {
        const elem = try self.arena.print("{s}[{d}]", .{ name, k });
        try self.out.discrete_inputs.put(self.arena, elem, tok);
        try lower_param.addParam(self, elem, ty, zero, folded, &.{}, false, tok);
    }
    try self.discrete_arrays.put(self.arena, name, .{ .lo = lo, .hi = hi });
}

test "§7.3.1 a digital reg array the analog block reads is one input per element" {
    // Table 7-1 lists `reg [0:9] r[0:7];` among the discrete variables read
    // in the continuous context "as integer numbers": each element its own
    // host-set input, the array no analog variable of its own.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  reg [3:0] r[1:3];
        \\  integer k;
        \\  initial begin r[1] = 1; r[3] = 3; end
        \\  analog begin
        \\    k = $rtoi(V(p));
        \\    I(p) <+ r[2] + r[k];
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    for ([_][]const u8{ "r[1]", "r[2]", "r[3]" }) |e| try std.testing.expect(h.low.out.discrete_inputs.contains(e));
    try std.testing.expect(!h.low.out.discrete_inputs.contains("r"));
    try std.testing.expect(h.low.arrays.get("r") == null);
}
