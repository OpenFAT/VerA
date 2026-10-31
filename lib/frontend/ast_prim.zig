//! The IEEE 1364 primitive rows of the AST: gate, switch and pull
//! instances (A.3), specify paths and timing checks (A.7), and user-defined
//! primitives (A.5); and the one walk over them, `primTerms`, which names
//! every primitive terminal. In: what the parser recognises. Out: rows read
//! by elaboration and the digital engine.
//! Cites: IEEE 1364-2005 §7 (gates and switches, §7.1-§7.13), §8 (UDPs),
//! §14 (specify), §15 (timing checks); LRM §7.8.5.1 (terminal names);
//! specification/Vague_Decisions.md VD-115.
//!
//! Contents:
//! - `pub const GateKind = enum`
//! - `pub const GateInst = struct`
//! - `pub const SpecEdge = enum(u8)`
//! - `pub const SpecPolarity = enum(u8)`
//! - `pub const SpecPath = struct`
//! - `pub const PulseControl = struct`
//! - `pub const TimingCheck = struct`: `posedge_mask`, `negedge_mask`, `transition`, `opposite`
//! - `pub const PullInst = struct`
//! - `pub const SwitchKind = enum(u8)`
//! - `pub const SwitchInst = struct`
//! - `pub const PrimTerm = struct`
//! - `pub const UdpRow = struct`
//! - `pub const UdpDecl = struct`
//! - `pub fn primTerms(a: std.mem.Allocator, file: *const SourceFile, m: *const ModuleDecl) std.mem.Allocator.Error![]PrimTerm`
//! - `pub fn setPrimTerm(a: std.mem.Allocator, gates: []GateInst, pulls: []PullInst, switches: []SwitchInst, t: PrimTerm, row: usize, x: ExprId) std.mem.Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const ExprId = ast.ExprId;
const StrId = ast.StrId;
const SourceFile = ast.SourceFile;
const ModuleDecl = ast.ModuleDecl;
const Strength = ast.Strength;
const NetStrength = ast.NetStrength;
const Delay3 = ast.Delay3;
const Dim = ast.Dim;
const Direction = ast.Direction;
const testing = std.testing;

/// A.3.4's gate types that compute a logic value. §7.8.5's tables define all
/// twelve; `n_input`, `n_output` and `enable` gates differ only in what their
/// terminal list means, which `GateInst` records in its shape.
pub const GateKind = enum { g_and, g_nand, g_or, g_nor, g_xor, g_xnor, g_buf, g_not, g_bufif0, g_bufif1, g_notif0, g_notif1 };

/// A.3.1 one `gate_instance`. `out` is the output terminal (§7.8.5.1's `out`;
/// a `buf`/`not` with several outputs becomes one `GateInst` per output, since
/// each is a separate driver). `ins` is the rest in source order: the inputs of
/// an n-input gate, `(data, enable)` for an enable gate, the single input of
/// `buf`/`not`. A gate drives `out` (§7.1), so it carries a `ContAssign`'s
/// strength and delay.
pub const GateInst = struct {
    kind: GateKind,
    out: ExprId,
    ins: []const ExprId,
    /// A.3.1 `name_of_gate_instance`, `.none` when not written.
    name: StrId = .none,
    /// IEEE 1364-2005 §7.1.5 an array of instances, `name [ range ]`: one
    /// gate per index, vector terminals split among them (§7.1.6).
    range: ?Dim = null,
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    delay: Delay3 = .{},
    main_tok: u32 = 0,
    /// Hoisted out of a generate block by an analog parse, which keeps no
    /// generate scope (`parser/generate.zig`); a digital parse leaves such a
    /// gate on its block, so it is not in the module's list there.
    generated: bool = false,
};

/// A.7.4 `edge_identifier` / A.7.5.3 `timing_check_event_control`.
pub const SpecEdge = enum(u8) { none, posedge, negedge, edge };

/// A.7.4 `polarity_operator`, absent when not written.
pub const SpecPolarity = enum(u8) { none, positive, negative };

/// A.7.2 one `path_declaration`: parallel (`=>`) or full (`*>`), simple or
/// edge-sensitive, optionally state-dependent.
pub const SpecPath = struct {
    full: bool,
    edge: SpecEdge = .none,
    /// The polarity before the arrow (a simple path's).
    polarity: SpecPolarity = .none,
    /// `if ( module_path_expression )`, or `.none`.
    cond: ExprId = .none,
    ifnone: bool = false,
    ins: []const ExprId,
    outs: []const ExprId,
    /// An edge-sensitive path's `data_source_expression` and the polarity
    /// written before its colon.
    data: ExprId = .none,
    data_polarity: SpecPolarity = .none,
    /// A.7.4 `list_of_path_delay_expressions`: 1, 2, 3, 6 or 12.
    delays: []const ExprId,
    main_tok: u32,
};

/// IEEE 1364-2005 §14.6 one pulse control of a specify block: an A.2.4
/// `pulse_control_specparam` (`limits`: `PATHPULSE$ = (reject [, error])`, or
/// `PATHPULSE$in$out = ...` for one path, `name` the whole specparam name)
/// or an A.7.1 pulsestyle or showcancelled declaration over `outs`.
pub const PulseControl = struct {
    kind: enum(u8) { limits, onevent, ondetect, showcancelled, noshowcancelled },
    name: StrId = .none,
    reject: ExprId = .none,
    /// `.none` when only the reject limit is written (§14.6.1: the error
    /// limit is then the same).
    err: ExprId = .none,
    outs: []const ExprId = &.{},
    main_tok: u32,
};

/// A.7.5.1 one `system_timing_check`: the command, and each argument slot in
/// order (`.none` for a slot A.7.5.1 lets be empty) with the event control
/// written on it.
pub const TimingCheck = struct {
    name: StrId,
    args: []const ExprId,
    edges: []const SpecEdge,
    /// Per argument slot, the IEEE 1364-2005 §15.4 transitions its
    /// `timing_check_event_control` names, one bit each (`transition`), a z
    /// read as x: `posedge` is `posedge_mask`, `negedge` `negedge_mask`, an
    /// `edge [...]` its descriptors; 0 for a slot with no event control.
    masks: []const u8 = &.{},
    /// Per argument slot, its A.7.5.3 `&&& timing_check_condition`, or
    /// `.none`.
    conds: []const ExprId = &.{},
    main_tok: u32,

    /// §15.4: "posedge clr is equivalent to ... edge[01, 0x, x1] clr".
    pub const posedge_mask: u8 = 0b100011;
    /// §15.4: "negedge clr is the same as ... edge[10, x0, 1x] clr".
    pub const negedge_mask: u8 = 0b011100;

    /// Returns the `masks` bit of the transition `from` -> `to` (§15.4:
    /// "Edge transitions involving z are treated the same way as edge
    /// transitions involving x"); 0 when they name none (the same level, or
    /// x to z). Bits 0..5 are 01, 0x, 10, 1x, x0, x1.
    /// Asserts each of `from` and `to` is `0`, `1`, `x` or `z`, lower case;
    /// the parser folds a descriptor's case before calling.
    pub fn transition(from: u8, to: u8) u8 {
        assert(std.mem.findScalar(u8, "01xz", from) != null);
        assert(std.mem.findScalar(u8, "01xz", to) != null);
        const f: u8 = if (from == 'z') 'x' else from;
        const t: u8 = if (to == 'z') 'x' else to;
        if (f == t) return 0;
        return switch (f) {
            '0' => if (t == '1') 1 << 0 else 1 << 1,
            '1' => if (t == '0') 1 << 2 else 1 << 3,
            else => if (t == '0') 1 << 4 else 1 << 5, // else: `x`, the only other level after the z fold
        };
    }

    /// Returns the transitions `mask` names, each turned around (01 <-> 10,
    /// 0x <-> x0, 1x <-> x1): §15.3.4's "reference event signal with
    /// opposite edge". An involution on bits 0..5; bits 6 and 7 are dropped.
    pub fn opposite(mask: u8) u8 {
        const swap = [6]u3{ 2, 4, 0, 5, 1, 3 };
        var out: u8 = 0;
        for (swap, 0..) |to, from| {
            if (mask & (@as(u8, 1) << @intCast(from)) != 0) out |= @as(u8, 1) << to;
        }
        return out;
    }
};

/// A.3.1 one `pull_gate_instance`, IEEE 1364-2005 §7.8's pullup/pulldown
/// source. It drives one constant, so it is not a `GateInst`: it has no
/// inputs and §7.8 gives it no delay. `strength` is the one side that counts
/// ("a strength0 specification on a pullup source ... shall be ignored").
pub const PullInst = struct {
    out: ExprId,
    /// `pullup` drives 1, `pulldown` drives 0.
    one: bool,
    strength: Strength = .pull,
    /// A.3.1 `name_of_gate_instance`, `.none` when not written.
    name: StrId = .none,
    /// `name_of_gate_instance ::= gate_instance_identifier [ range ]`: an
    /// instance array (IEEE 1364-2005 §7.1.5), as `GateInst.range`.
    range: ?Dim = null,
    main_tok: u32 = 0,
    /// As `GateInst.generated`.
    generated: bool = false,
};

/// A.3.4's switch types (IEEE 1364-2005 §7.6/§7.7): the MOS and CMOS switches
/// pass their input one way, the pass switches conduct both ways; an `r`
/// prefix is the resistive variant (§7.12's strength reduction).
pub const SwitchKind = enum(u8) { cmos, rcmos, nmos, pmos, rnmos, rpmos, tran, rtran, tranif0, tranif1, rtranif0, rtranif1 };

/// A.3.1 one switch instance: its terminals in source order (output, input,
/// control(s) for a MOS/CMOS switch; the two inout terminals, then the
/// enable, for a pass switch).
pub const SwitchInst = struct {
    kind: SwitchKind,
    terms: []const ExprId,
    delay: Delay3 = .{},
    /// A.3.1 `name_of_gate_instance`, `.none` when not written, and its
    /// §7.1.5 instance-array range.
    name: StrId = .none,
    range: ?Dim = null,
    main_tok: u32 = 0,
    /// As `GateInst.generated`.
    generated: bool = false,
};

/// One terminal of a built-in primitive as VAMS §7.8.5.1 names it "for the
/// purpose of naming the connect modules" §7.8.4 inserts on it (§7.8.5's
/// `SigName__InstName__PortName`).
pub const PrimTerm = struct {
    /// The module list that holds the primitive, and its row there.
    list: enum { gate, pull, switch_ },
    row: u32,
    /// 0 a gate's `out`, k its `ins[k - 1]`; a pull's terminal; a switch's
    /// `terms[k]`.
    term: u32,
    /// §7.8.5's InstName, before an instance array's `[k]` (`range`).
    inst: []const u8,
    range: ?Dim,
    port: []const u8,
    /// IEEE 1364-2005 A.3.3's direction of the terminal, which §7.8.4's
    /// matching reads as a port's.
    dir: Direction,
    expr: ExprId,
    generated: bool,
    main_tok: u32,
};

/// One A.5.3 `combinational_entry` or `sequential_entry`, as the characters of
/// its columns. A.5.3's alphabets are characters: an `edge_indicator ::= (
/// level_symbol level_symbol )` is one input field that lexes as three tokens,
/// so `parseUdpEntry` concatenates each column's token text.
pub const UdpRow = struct {
    /// `level_input_list` or `seq_input_list`, validated against A.5.3's
    /// alphabets, `( )` included so an edge entry keeps its grouping.
    inputs: []const u8,
    /// `current_state ::= level_symbol`; 0 for a combinational entry, which
    /// has no such column.
    state: u8 = 0,
    /// `output_symbol ::= 0 | 1 | x | X`, or `-` for a `next_state` that holds.
    output: u8,
};

// ponytail: `UdpRow.inputs` is not split into one field per input port; the
// evaluator is where that split has a consumer, and where the per-port field
// count can be checked with a diagnostic.
/// LRM §8.5.3 / A.5.1 `udp_declaration` as validated by `parseUdpDecl`.
/// Evaluating it belongs to whatever executes the discrete cycle.
pub const UdpDecl = struct {
    name: StrId,
    /// A.5.2 `udp_port_list ::= output_port_identifier , input_port_identifier
    /// { , input_port_identifier }`, so `ports[0]` is the output and
    /// `ports[1..]` are the inputs, in the order A.5.3's input list is written
    /// in. Both A.5.1 header arms produce the same order.
    ports: []const StrId = &.{},
    /// Which A.5.3 `udp_body` alternative the table is, taken from the table
    /// itself: a `sequential_entry` is the two-colon one, and `parseUdpTable`
    /// already requires every entry to agree.
    ///
    /// Not taken from the `reg` on the output declaration. A.5.2 admits one
    /// there and A.5.3 decides the body; a UDP that writes `reg` over a
    /// combinational table is malformed, and nothing checks that yet.
    is_sequential: bool = false,
    /// A.5.3 `udp_initial_statement ::= initial output_port_identifier =
    /// init_val ;`; `.none` when the declaration carries none.
    init: ExprId = .none,
    /// The identifier the initial statement assigns (§8.1.3: the output).
    init_target: StrId = .none,
    /// The ports declared `output`, the last one's name, and whether any
    /// `reg` is declared: IEEE 1364-2005 §8.1.1 wants exactly one output,
    /// first in the list; §8.1.2 a `reg` for a sequential UDP's output and
    /// none in a combinational one. The digital engine judges them.
    outputs: u8 = 0,
    output: StrId = .none,
    has_reg: bool = false,
    rows: []const UdpRow = &.{},
    main_tok: u32 = 0,
};

/// Every terminal of `m`'s primitives, named by VAMS §7.8.5.1, in source
/// order. The one naming rule for the analog compile's insertion
/// (`elab/insert.zig`) and the mixed runner's (`lib/sim/digital/elab.zig`
/// `bridged`), which meet only through these strings.
///
/// - "For N-input gates (and, nand, nor, or, xnor, xor) the output will be
///   named out, and the inputs reading from left to right will be in1, in2,
///   in3". "For N-output gates (buf, not) The input will be named in, and the
///   outputs reading from left to right will be named out1, out2, out3": such
///   a gate is one row per output, so an output's number is its row's place
///   among its instance's rows (one `main_tok`), and `in` is listed once, on
///   the first row.
/// - "3 port MOS switches (nmos, pmos, rnmos, rpmos) ... source, drain, gate";
///   "4 port MOS switches (cmos, rcmos) ... source, drain, ngate, pgate";
///   "bidirectional pass switches (tran, tranif1, tranif0, rtran, rtranif1,
///   rtranif) ... source, drain, gate"; "single port primitives (pullup,
///   pulldown) ... out". Left to right is the A.3.1 terminal order.
/// - The enable gates (bufif0, bufif1, notif0, notif1), which the clause does
///   not name: `out`, `in`, `enable`, left to right (VerA's choice, after the
///   N-input names; Vague_Decisions VD-115).
///
/// InstName is the instance's name. IEEE 1364-2005 A.3.1 makes it optional
/// and neither standard names an unnamed instance (VerA's VPI gives it none),
/// so one is `<gatetype>$<n>`, n counting from 1 the module's unnamed
/// instances of that type in source order (VD-115). A primitive an analog
/// parse hoisted out of a generate block is not counted, so the numbers match
/// a digital parse's, which keeps it on its block; it is listed with its
/// type name alone.
///
/// The result, every generated name and the scratch map all live in `a`,
/// and nothing is freed: pass an arena.
pub fn primTerms(a: std.mem.Allocator, file: *const SourceFile, m: *const ModuleDecl) std.mem.Allocator.Error![]PrimTerm {
    var out: std.ArrayList(PrimTerm) = .empty;
    // Unnamed instances seen per type name, for `<gatetype>$<n>`.
    var unnamed: std.StringHashMapUnmanaged(u32) = .empty;
    const Name = struct {
        fn of(al: std.mem.Allocator, f: *const SourceFile, seen: *std.StringHashMapUnmanaged(u32), name: StrId, ty: []const u8, generated: bool) ![]const u8 {
            if (name != .none) return f.str(name);
            if (generated) return ty;
            const n = try seen.getOrPutValue(al, ty, 0);
            n.value_ptr.* += 1;
            return al.print("{s}${d}", .{ ty, n.value_ptr.* });
        }
    };
    var inst: []const u8 = "";
    var k: u32 = 0; // the row's place among its instance's rows
    for (m.gates, 0..) |g, gi| {
        const first = gi == 0 or m.gates[gi - 1].main_tok != g.main_tok;
        k = if (first) 1 else k + 1;
        if (first) inst = try Name.of(a, file, &unnamed, g.name, @tagName(g.kind)[2..], g.generated);
        for (0..1 + g.ins.len) |t| {
            const port: []const u8, const dir: Direction = switch (g.kind) {
                .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => if (t == 0) .{ "out", .output } else .{ try a.print("in{d}", .{t}), .input },
                .g_buf, .g_not => if (t == 0) .{ try a.print("out{d}", .{k}), .output } else if (first) .{ "in", .input } else continue,
                .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => .{ ([_][]const u8{ "out", "in", "enable" })[t], if (t == 0) .output else .input },
            };
            try out.append(a, .{ .list = .gate, .row = @intCast(gi), .term = @intCast(t), .inst = inst, .range = g.range, .port = port, .dir = dir, .expr = if (t == 0) g.out else g.ins[t - 1], .generated = g.generated, .main_tok = g.main_tok });
        }
    }
    for (m.pulls, 0..) |p, pi| try out.append(a, .{
        .list = .pull,
        .row = @intCast(pi),
        .term = 0,
        .inst = try Name.of(a, file, &unnamed, p.name, if (p.one) "pullup" else "pulldown", p.generated),
        .range = null,
        .port = "out",
        .dir = .output,
        .expr = p.out,
        .generated = p.generated,
        .main_tok = p.main_tok,
    });
    for (m.switches, 0..) |sw, si| {
        const name = try Name.of(a, file, &unnamed, sw.name, @tagName(sw.kind), sw.generated);
        const ports: []const []const u8, const dirs: []const Direction = switch (sw.kind) {
            .nmos, .pmos, .rnmos, .rpmos => .{ &.{ "source", "drain", "gate" }, &.{ .output, .input, .input } },
            .cmos, .rcmos => .{ &.{ "source", "drain", "ngate", "pgate" }, &.{ .output, .input, .input, .input } },
            .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => .{ &.{ "source", "drain", "gate" }, &.{ .inout, .inout, .input } },
        };
        for (sw.terms, 0..) |x, t| try out.append(a, .{ .list = .switch_, .row = @intCast(si), .term = @intCast(t), .inst = name, .range = sw.range, .port = ports[t], .dir = dirs[t], .expr = x, .generated = sw.generated, .main_tok = sw.main_tok });
    }
    return out.items;
}

/// Points terminal `t.term` of the primitive `t` names at `x`, in rows laid
/// out like the module's lists `primTerms` read (`row` is `t.row`, or the
/// same row of a flattened list). A `buf`/`not` input re-points every output
/// row of its instance (one `main_tok`), since `primTerms` lists it once.
/// A changed `ins` or `terms` list is a fresh copy in `a` (the old one may
/// be shared and is never written or freed); `out` is written in place.
pub fn setPrimTerm(a: std.mem.Allocator, gates: []GateInst, pulls: []PullInst, switches: []SwitchInst, t: PrimTerm, row: usize, x: ExprId) std.mem.Allocator.Error!void {
    assert(x != .none);
    switch (t.list) {
        .gate => {
            assert(row < gates.len);
            var i = row;
            while (i < gates.len and gates[i].main_tok == gates[row].main_tok) : (i += 1) {
                const g = &gates[i];
                if (t.term == 0) {
                    g.out = x;
                    return;
                }
                const ins = try a.dupe(ExprId, g.ins);
                ins[t.term - 1] = x;
                g.ins = ins;
            }
        },
        .pull => {
            assert(row < pulls.len);
            pulls[row].out = x;
        },
        .switch_ => {
            assert(row < switches.len);
            assert(t.term < switches[row].terms.len);
            const terms = try a.dupe(ExprId, switches[row].terms);
            terms[t.term] = x;
            switches[row].terms = terms;
        },
    }
}

// ---- private ----

test "TimingCheck.transition: every level pair, z read as x (§15.4)" {
    const levels = "01xz";
    // Rows `from`, columns `to`, both in the order 0 1 x z. Bit values:
    // 01 = 1, 0x = 2, 10 = 4, 1x = 8, x0 = 16, x1 = 32.
    const want = [4][4]u8{
        .{ 0, 1, 2, 2 },
        .{ 4, 0, 8, 8 },
        .{ 16, 32, 0, 0 },
        .{ 16, 32, 0, 0 },
    };
    for (levels, 0..) |from, i| {
        for (levels, 0..) |to, j| try std.testing.expectEqual(want[i][j], TimingCheck.transition(from, to));
    }
    // §15.4's two equivalences, built from the single transitions.
    const t = TimingCheck.transition;
    try std.testing.expectEqual(TimingCheck.posedge_mask, t('0', '1') | t('0', 'x') | t('x', '1'));
    try std.testing.expectEqual(TimingCheck.negedge_mask, t('1', '0') | t('x', '0') | t('1', 'x'));
}

test "TimingCheck.opposite turns each transition around and is an involution" {
    for (0..64) |m| {
        const mask: u8 = @intCast(m);
        try std.testing.expectEqual(mask, TimingCheck.opposite(TimingCheck.opposite(mask)));
        try std.testing.expectEqual(@popCount(mask), @popCount(TimingCheck.opposite(mask)));
    }
    try std.testing.expectEqual(TimingCheck.negedge_mask, TimingCheck.opposite(TimingCheck.posedge_mask));
    const levels = "01x";
    for (levels) |from| {
        for (levels) |to| {
            if (from == to) continue;
            try std.testing.expectEqual(TimingCheck.transition(to, from), TimingCheck.opposite(TimingCheck.transition(from, to)));
        }
    }
    try std.testing.expectEqual(@as(u8, 0), TimingCheck.opposite(0b1100_0000));
}

test "primTerms names every primitive terminal as VAMS §7.8.5.1 does, numbering unnamed instances per type (VD-115)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: SourceFile = .empty;
    const e = struct {
        fn id(n: u32) ExprId {
            return @fromBackingInt(n);
        }
    }.id;
    // and (o, a, b); and g2 (o2, c, d); buf (x, y, i); bufif0 (q, d, en);
    // a hoisted `and` (generated, unnamed); and (p, r, s);
    const gates = [_]GateInst{
        .{ .kind = .g_and, .out = e(0), .ins = &.{ e(1), e(2) }, .main_tok = 1 },
        .{ .kind = .g_and, .out = e(3), .ins = &.{ e(4), e(5) }, .name = try f.intern(a, "g2"), .main_tok = 2 },
        .{ .kind = .g_buf, .out = e(6), .ins = &.{e(8)}, .main_tok = 3 },
        .{ .kind = .g_buf, .out = e(7), .ins = &.{e(8)}, .main_tok = 3 },
        .{ .kind = .g_bufif0, .out = e(9), .ins = &.{ e(10), e(11) }, .main_tok = 4 },
        .{ .kind = .g_and, .out = e(12), .ins = &.{e(13)}, .main_tok = 5, .generated = true },
        .{ .kind = .g_and, .out = e(14), .ins = &.{e(15)}, .main_tok = 6 },
    };
    const pulls = [_]PullInst{.{ .out = e(16), .one = true, .main_tok = 7 }};
    const switches = [_]SwitchInst{
        .{ .kind = .nmos, .terms = &.{ e(17), e(18), e(19) }, .main_tok = 8 },
        .{ .kind = .tran, .terms = &.{ e(20), e(21) }, .main_tok = 9 },
    };
    const m: ModuleDecl = .{ .name = try f.intern(a, "m"), .ports = &.{}, .gates = &gates, .pulls = &pulls, .switches = &switches };
    const Want = struct { []const u8, []const u8, Direction, u32 };
    const want = [_]Want{
        .{ "and$1", "out", .output, 0 },    .{ "and$1", "in1", .input, 1 },      .{ "and$1", "in2", .input, 2 },
        .{ "g2", "out", .output, 3 },       .{ "g2", "in1", .input, 4 },         .{ "g2", "in2", .input, 5 },
        // One buf, two output rows: `in` is listed once, on the first.
        .{ "buf$1", "out1", .output, 6 },   .{ "buf$1", "in", .input, 8 },       .{ "buf$1", "out2", .output, 7 },
        .{ "bufif0$1", "out", .output, 9 }, .{ "bufif0$1", "in", .input, 10 },   .{ "bufif0$1", "enable", .input, 11 },
        // Hoisted: its type name, not counted, so the next one is `and$2`.
        .{ "and", "out", .output, 12 },     .{ "and", "in1", .input, 13 },       .{ "and$2", "out", .output, 14 },
        .{ "and$2", "in1", .input, 15 },    .{ "pullup$1", "out", .output, 16 }, .{ "nmos$1", "source", .output, 17 },
        .{ "nmos$1", "drain", .input, 18 }, .{ "nmos$1", "gate", .input, 19 },   .{ "tran$1", "source", .inout, 20 },
        .{ "tran$1", "drain", .inout, 21 },
    };
    const got = try primTerms(a, &f, &m);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqualStrings(w[0], g.inst);
        try std.testing.expectEqualStrings(w[1], g.port);
        try std.testing.expectEqual(w[2], g.dir);
        try std.testing.expectEqual(e(w[3]), g.expr);
    }
}

test "setPrimTerm re-points one terminal; a buf's shared input on every output row" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const e = struct {
        fn id(n: u32) ExprId {
            return @fromBackingInt(n);
        }
    }.id;
    const in = [_]ExprId{e(8)};
    var gates = [_]GateInst{
        .{ .kind = .g_buf, .out = e(6), .ins = &in, .main_tok = 3 },
        .{ .kind = .g_buf, .out = e(7), .ins = &in, .main_tok = 3 },
        .{ .kind = .g_and, .out = e(0), .ins = &.{ e(1), e(2) }, .main_tok = 4 },
    };
    var pulls = [_]PullInst{.{ .out = e(16), .one = false }};
    const terms = [_]ExprId{ e(17), e(18), e(19) };
    var switches = [_]SwitchInst{.{ .kind = .nmos, .terms = &terms }};
    const t: PrimTerm = .{ .list = .gate, .row = 0, .term = 1, .inst = "buf$1", .range = null, .port = "in", .dir = .input, .expr = e(8), .generated = false, .main_tok = 3 };
    try setPrimTerm(a, &gates, &pulls, &switches, t, 0, e(99));
    try std.testing.expectEqual(e(99), gates[0].ins[0]);
    try std.testing.expectEqual(e(99), gates[1].ins[0]);
    try std.testing.expectEqual(e(1), gates[2].ins[0]); // another instance
    try std.testing.expectEqual(e(8), in[0]); // copied, never written through
    var out = t;
    out.term = 0;
    try setPrimTerm(a, &gates, &pulls, &switches, out, 1, e(98));
    try std.testing.expectEqual(e(6), gates[0].out);
    try std.testing.expectEqual(e(98), gates[1].out);
    try setPrimTerm(a, &gates, &pulls, &switches, .{ .list = .pull, .row = 0, .term = 0, .inst = "", .range = null, .port = "out", .dir = .output, .expr = e(16), .generated = false, .main_tok = 0 }, 0, e(97));
    try std.testing.expectEqual(e(97), pulls[0].out);
    try setPrimTerm(a, &gates, &pulls, &switches, .{ .list = .switch_, .row = 0, .term = 2, .inst = "", .range = null, .port = "gate", .dir = .input, .expr = e(19), .generated = false, .main_tok = 0 }, 0, e(96));
    try std.testing.expectEqualSlices(ExprId, &.{ e(17), e(18), e(96) }, switches[0].terms);
    try std.testing.expectEqual(e(19), terms[2]);
}
