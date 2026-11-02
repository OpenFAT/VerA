//! Codegen self-checks: a small Verilog-A source in, device.zig text out,
//! asserted by shape; the fixture suite checks behaviour. Also runs the
//! device-runtime kernels directly.
//! LRM §3.4, §4.5, §4.6, §5.4.3, §5.6, §9.4, §9.5, §9.13, §9.17.3, §9.21.

const exe_tests = @import("exe_tests.zig");
const std = @import("std");
/// The device backend (`src/codegen/device/`).
const codegen = @import("device");
const gen_kernel_text = codegen.kernel_text;
const Harness = codegen.Harness;
const Ast = @import("frontend").Ast;
const Parser = @import("frontend").Parser;
const ifconv = @import("prove").ifconv;
const Mir = @import("ir").Mir;
const Lower = @import("analog").Lower;
const Lowered = @import("ir").Lowered;
const proof = @import("prove").proof;
const diag = @import("diag");
const assert = std.debug.assert;
const Output = codegen.Output;
const generate = codegen.generate;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "codegen: an unused integer remainder keeps its artifact-specific zero check" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer d, unused;
        \\  analog begin
        \\    d = V(p,n);
        \\    unused = 11 % d;
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const device = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, device, "zm_b == 0) { @trap();") != null);
    try std.testing.expect(std.mem.find(u8, device, "error[E0601]") == null);
    const executable = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, executable, "error[E0601]") != null);
    try std.testing.expect(std.mem.find(u8, executable, "std.process.exit(1)") != null);
}

test "codegen: a discarded remainder inside a display argument stays in the display phase" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog function integer f;
        \\    input d; integer d, unused;
        \\    begin unused = 11 % d; f = 7; end
        \\  endfunction
        \\  analog begin
        \\    $strobe("%d", f($rtoi(V(p,n))));
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectEqual(Mir.Value.f_zero, h.lowered.table_effect);
    const device = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, device, "fn zm_f") == null);
    const executable = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, executable, "error[E0601]") != null);
}

const resistor_va =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "codegen: --jac-f32 adds a permission decl and changes not one other byte" {
    // `eval` reaches S only through primitives that take and return f64
    // (`con`, `scale`, `addC`, `val`), so the derivative width inside S is the
    // host's choice and no emitted arithmetic depends on it. Any other byte
    // the flag moves means that genericity broke.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();

    const v = try proof.prove(std.testing.allocator, &h.mir, &h.lowered, .{}, &h.bag);
    defer v.deinit(std.testing.allocator);
    const a = h.arena_state.allocator();
    const off = (try generate(a, a, &h.mir, &h.lowered, v, .{})).output.text;
    const on = (try generate(a, a, &h.mir, &h.lowered, v, .{ .jac_f32 = true })).output.text;

    try std.testing.expect(std.mem.find(u8, off, "jac_f32") == null);
    const decl = "pub const jac_f32 = true;\n\n";
    const at = std.mem.find(u8, on, decl) orelse return error.NoPermissionDecl;
    // Excise the block the flag added (comment header included) and what is
    // left has to be the default output byte for byte.
    const hdr = std.mem.findLast(u8, on[0..at], "/// This device permits").?;
    const stripped = try std.mem.concat(a, u8, &.{ on[0..hdr], on[at + decl.len ..] });
    try std.testing.expectEqualStrings(off, stripped);

    // `--jac-f32-host` is the stronger request and emits the permission too:
    // a host width without the permission is the one combination
    // `lib/contract.zig` rejects, so codegen must never produce it.
    const host = (try generate(a, a, &h.mir, &h.lowered, v, .{ .jac_f32_host = true })).output.text;
    try std.testing.expect(std.mem.find(u8, host, decl) != null);
    try std.testing.expect(std.mem.find(u8, host, "pub const jac_f32_host = true;") != null);
}

test "codegen: the family text types each merge by its unknowns" {
    // a = 0, c = 1, b = 2: the `if` merges exp(V(a,c)), lanes {a, c}, with
    // V(b), lane {b}, so the slot both arms write and the field are 0x7.
    const src =
        \\module d(a, c, b);
        \\  inout a, c, b;
        \\  electrical a, c, b;
        \\  real i;
        \\  analog begin
        \\    if (V(a, c) > 0.5) i = exp(V(a, c)); else i = V(b);
        \\    I(a, c) <+ i;
        \\  end
        \\endmodule
    ;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, src, &h);
    defer h.deinit();
    const v = try proof.prove(std.testing.allocator, &h.mir, &h.lowered, .{}, &h.bag);
    defer v.deinit(std.testing.allocator);
    const a = h.arena_state.allocator();
    const on = (try generate(a, a, &h.mir, &h.lowered, v, .{})).output.text;
    for ([_][]const u8{
        "fn d__common__core(comptime S: type, x: anytype, ",
        "    f0: zOf(S, 0x7),\n",
        "    var h0: [1]zOf(S, 0x7) = undefined;\n",
        "h0[0] = zTo(S, 0x7, x[@intFromEnum(U.b)]);",
        "        .f0 = zTo(S, 0x7, t",
        "res[@intFromEnum(U.a)] = zRow(S, .a, res[@intFromEnum(U.a)].add(c));",
        "pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {",
        "pub const lane_masks = [_]contract.LaneUse{",
        "    .{ .mask = 0x7, .uses = ",
    }) |s| if (std.mem.find(u8, on, s) == null) {
        std.debug.print("missing from the family text: {s}\n", .{s});
        return error.TestExpectedEqual;
    };
}

test "codegen: a core reads time and analysis from its SimState argument, and names it only then" {
    // The resistor's core reads none of it, so its `sim` is discarded.
    {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, resistor_va, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.find(u8, src, ", _  : contract.SimState) struct {") != null);
        try std.testing.expect(std.mem.find(u8, src, "core_reads_simstate") == null);
    }
    {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator,
            \\module ak(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ V(p, n) * (analysis("tran") ? 2.0 : 1.0) + 1e-3 * V(p, n) * $abstime;
            \\endmodule
        , &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.find(u8, src, "InstancePtr, sim: contract.SimState) struct {") != null);
        try std.testing.expect(std.mem.find(u8, src, "(sim.kind == .tran or sim.kind == .ic)") != null);
        try std.testing.expect(std.mem.find(u8, src, "S.con(sim.t)") != null);
        try std.testing.expect(std.mem.find(u8, src, "analysis_kind") == null);
    }
}

test "codegen: `constant` is declared exactly for a Jacobian no x can move" {
    const cases = [_]struct { body: []const u8, want: ?[]const u8 }{
        // V/r with r from the card; a capacitor; an inductor.
        .{ .body = "I(p, n) <+ V(p, n) / r;", .want = ".{ .g = true, .c = false }" },
        .{ .body = "I(p, n) <+ ddt(1e-12 * V(p, n));", .want = ".{ .g = true, .c = true }" },
        .{ .body = "V(p, n) <+ 1e-9 * ddt(I(p, n));", .want = ".{ .g = true, .c = true }" },
        // A partial that moves with x, with time, or with the branch x took.
        .{ .body = "I(p, n) <+ exp(V(p, n));", .want = null },
        .{ .body = "I(p, n) <+ 1e-3 * V(p, n) * $abstime;", .want = null },
        .{ .body = "if (V(p, n) > 0) I(p, n) <+ V(p, n) / r; else I(p, n) <+ 2.0 * V(p, n);", .want = null },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module k(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0:inf);
            \\  analog {s}
            \\endmodule
        , .{c.body});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);
        const at = std.mem.find(u8, out, "pub const constant: contract.Constant = ");
        if (c.want) |w| {
            try std.testing.expect(std.mem.startsWith(u8, out[at.? + "pub const constant: contract.Constant = ".len ..], w));
        } else try std.testing.expect(at == null);
    }
}

test "codegen: State.t_prev exists only for a reader, and state_class is declared" {
    // A constant-td `absdelay` pushes its ring on `sim.t` and never
    // reads `t_prev`; `idtmod` integrates over `dt = abstime - t_prev`. A
    // nonlinear `ddt` lowers to the §5.6.1.2 path latches alone.
    const cases = [_]struct { src: []const u8, t_prev: bool, class: []const u8 }{
        .{ .src =
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ absdelay(V(p, n), 1e-9);
        \\endmodule
        , .t_prev = false, .class = ".history" },
        .{ .src =
        \\module l(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ idtmod(V(p, n), 0.0, 1.0);
        \\endmodule
        , .t_prev = true, .class = ".history" },
        .{ .src =
        \\module c(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * ddt(V(p, n));
        \\endmodule
        , .t_prev = false, .class = ".path_latch" },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expectEqual(c.t_prev, std.mem.find(u8, src, "t_prev: f64") != null);
        try std.testing.expectEqual(c.t_prev, std.mem.find(u8, src, "state.t_prev = sim.t;") != null);
        const decl = try h.arena_state.allocator().print("pub const state_class: contract.StateClass = {s};", .{c.class});
        try std.testing.expect(std.mem.find(u8, src, decl) != null);
    }
}

test "codegen: a vera_interp = 2 absdelay site publishes exactly a linear site's state and delays" {
    // The host finds delay state by the `__absdelay__` field infix and sizes
    // its breakpoints from `delays`: the attribute may change the kernel only.
    const srcs = [2][]const u8{
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ absdelay(V(p, n), 1e-9) + absdelay(V(p, n), 2e-9);
        \\endmodule
        ,
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ absdelay(V(p, n), 1e-9) + absdelay (* vera_interp = 2 *) (V(p, n), 2e-9);
        \\endmodule
    };
    var out: [2][]const u8 = undefined;
    var hs: [2]Harness = undefined;
    for (srcs, &out, &hs) |s, *o, *h| {
        try Harness.run(std.testing.allocator, s, h);
        o.* = try h.gen(std.testing.allocator);
    }
    defer for (&hs) |*h| h.deinit();
    try std.testing.expect(std.mem.find(u8, out[0], "zAbsdelayQ(") == null);
    try std.testing.expect(std.mem.find(u8, out[1], "zAbsdelayQ(zL(S,") != null);
    try std.testing.expectEqual(std.mem.count(u8, out[0], "d__analog_op__absdelay__"), std.mem.count(u8, out[1], "d__analog_op__absdelay__"));
    try std.testing.expect(std.mem.find(u8, out[1], "Z24") == null);
    const delays = "pub fn delays(_: *const Model) [2]f64 {\n    return .{ 0.000000001, 0.000000002 };\n}";
    for (out) |o| try std.testing.expect(std.mem.find(u8, o, delays) != null);
}

test "codegen: acceptQ is q and updateState off ONE core evaluation" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module c(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * ddt(V(p, n));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.find(u8, src, "pub fn acceptQ(comptime S: type,") orelse return error.NoAcceptQ;
    const body = src[at..][0 .. std.mem.find(u8, src[at..], "\n}\n") orelse return error.NoEnd];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "@call(.always_inline, core,"));
    try std.testing.expect(std.mem.find(u8, body, "state.wq__0 = m.f") != null);
    try std.testing.expect(std.mem.find(u8, body, "return qq;") != null);
}

test "codegen: §5.10 eval skips a held-array store only updateState reads, and never copies the array" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module hh(p, n);
        \\  inout p, n; electrical p, n;
        \\  real hist[0:3]; integer k, nh;
        \\  analog begin
        \\    @(initial_step) begin
        \\      nh = 0;
        \\      for (k = 0; k < 4; k = k + 1) hist[k] = 0.0;
        \\    end
        \\    I(p, n) <+ V(p, n) * hist[0];
        \\    if (nh < 4) begin
        \\      hist[nh] = V(p, n);
        \\      hist[0] = hist[nh] * 2.0;
        \\      nh = nh + 1;
        \\    end
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "inst: InstancePtr, sim: contract.SimState, comptime held: bool) struct {") != null);
    // The append and the store that reads it back are skippable; the
    // initial-step zeroing is read by the residual in the same evaluation.
    // Both appear twice: in the core, and in `updateState`'s slice of it.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "if (held) zArrSt("));
    try std.testing.expect(std.mem.find(u8, src, "p0 = &inst.") != null);
    try std.testing.expect(std.mem.find(u8, src, "core, .{ S, xs, model, inst, sim, false })") != null);
    try std.testing.expect(std.mem.find(u8, src, "core__state(S, zVals(S, &x), model, inst, sim, true)") != null);
    // The read-back carries V's derivative, but into nothing eval returns,
    // so the storage stays plain.
    try std.testing.expect(std.mem.find(u8, src, "var a0: [4]f64 = undefined;") != null);
    // `updateState`'s slice stores in place (`state.inPlaceArrays`): a
    // mutable pointer at the field, no copy-in, no array field to return and
    // no write-back.
    try std.testing.expect(std.mem.find(u8, src, "var p0: *[4]f64 = undefined;") != null);
    try std.testing.expect(std.mem.find(u8, src, "if (held) zArrSt(f64, p0, ") != null);
    try std.testing.expect(std.mem.find(u8, src, "inst.hh__held__hist = m.f") == null);
}

test "codegen: §5.10 stateCtl copies only the written range of a long in-place held array" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dr(p, n);
        \\  inout p, n; electrical p, n;
        \\  real hist[0:99], few[0:3]; integer k, nh;
        \\  analog begin
        \\    @(initial_step) begin
        \\      nh = 0;
        \\      for (k = 0; k < 100; k = k + 1) hist[k] = 0.0;
        \\      for (k = 0; k < 4; k = k + 1) few[k] = 0.0;
        \\    end
        \\    I(p, n) <+ V(p, n) * hist[0] + few[1];
        \\    if (nh < 100) begin
        \\      hist[nh] = V(p, n);
        \\      few[nh % 4] = V(p, n);
        \\      nh = nh + 1;
        \\    end
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The 100-element history carries a range; the 4-element one is copied
    // whole (`file.dirty_min_len`).
    try std.testing.expect(std.mem.find(u8, src, "dr__held__hist__dirty: [2]i64 = .{ 0, 99 },") != null);
    try std.testing.expect(std.mem.find(u8, src, "dr__held__few__dirty") == null);
    try std.testing.expect(std.mem.find(u8, src, "zArrStD(f64, p") != null);
    try std.testing.expect(std.mem.find(u8, src, "zArrSync(f64, &state.dr__held__hist, &inst.dr__held__hist, &inst.dr__held__hist__dirty);") != null);
    try std.testing.expect(std.mem.find(u8, src, "zArrSync(f64, &inst.dr__held__hist, &state.dr__held__hist, &inst.dr__held__hist__dirty);") != null);
    try std.testing.expect(std.mem.find(u8, src, "state.dr__held__few = inst.dr__held__few;") != null);
    // A fresh `State` matches `inst` nowhere in particular: the whole range.
    try std.testing.expect(std.mem.find(u8, src, "    inst.dr__held__hist__dirty = .{ 0, 99 };\n    return .{};") != null);
}

test "codegen: §3.2 a memory-backed array starts each evaluation with @memset" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module zf(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer sp;
        \\  (* vera_scratch *) real st[0:31];
        \\  analog begin
        \\    sp = ($abstime < 0.5) ? 1 : 2;
        \\    st[sp] = V(p, n);
        \\    I(p, n) <+ st[sp] + st[sp - 1];
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "@memset(&a") != null);
}

test "codegen: one stably-named declaration for the model, thin dispatcher" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, src, "pub const U = enum(u8) {") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.find(u8, src, "r: f64 = 1000.0,") != null);
    // The declaration name is `ir/names.zig`'s structural key, not a MIR index,
    // and there is one per model. The per-contribution keys (`ir/names.zig`,
    // proof.zig, the `Instance` state fields) name no declaration.
    try std.testing.expect(std.mem.find(u8, src, "fn res__common__core(comptime S: type,") != null);
    try std.testing.expect(std.mem.find(u8, src, "return zResidual(S, xs, @call(.always_inline, core, .{ S, xs, model, inst, sim }));") != null);
    try std.testing.expect(std.mem.find(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.find(u8, src, "contract.validate(Self)") != null);
    // no reactive part ⇒ no q()
    try std.testing.expect(std.mem.find(u8, src, "pub fn q(") == null);
    // NEVER a global MIR value index in a name
    try std.testing.expect(std.mem.find(u8, src, "v12") == null);
}

const shared_va =
    \\module sh(p, n);
    \\  inout p, n;
    \\  electrical p, n, m;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  real g;
    \\  analog begin
    \\    g = exp(V(p, n) / r) * V(p, m);
    \\    I(p, m) <+ g * 2.0;
    \\    I(m, n) <+ g * 3.0;
    \\  end
    \\endmodule
;

test "codegen: two contributions sharing a subexpression evaluate it ONCE" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, shared_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One declaration, named structurally, with no MIR index anywhere in it.
    try std.testing.expect(std.mem.find(u8, src, "fn sh__common__core(comptime S: type,") != null);
    // One call for the whole residual, not one per contribution. LLVM does
    // not CSE repeated calls to a body this size (see `plan_core.plan`), so
    // the count is the number of core runs per Newton iteration.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, src, "return zResidual(S, xs, @call(.always_inline, core, .{ S, xs, model, inst, sim }));"),
    );
    try std.testing.expect(std.mem.find(u8, src, "const c = m.f0;") != null);
    // The costly `exp` is emitted once. Counted past the file-scope helpers,
    // several of which spell `.exp()` themselves.
    const decls = src[std.mem.find(u8, src, "// ---- the model, in one declaration ----").?..];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, decls, ".exp()"));

    // §4.3: `exp` of an unbounded probe is not provably finite, so both units
    // are `.strict` and the declaration they share must be too: compiling it
    // `.optimized` would assert `ninf` on behalf of a unit that never had it.
    const at = std.mem.find(u8, src, "fn sh__common__core").?;
    try std.testing.expect(std.mem.find(u8, src[at..], "@setFloatMode(.strict);") != null);
}

test "codegen: one declaration even for a single contribution" {
    // No threshold: one contribution gets the same shape as fifty, because
    // `eval` reads its targets out of one struct. The extra call is free; LLVM
    // inlines a core this small.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "fn res__common__core(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "return zResidual(S, xs, @call(.always_inline, core, .{ S, xs, model, inst, sim }));"));
}

test "codegen: the unit ranges tile the emission and each names its own decl" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  parameter real c = 1e-12;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(p, n) <+ ddt(c * V(p, n));
        \\    V(p, n) <+ laplace_nd(V(p, n), '{1.0}, '{1.0, 1.0});
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const o = try h.genOut(std.testing.allocator);

    // The merged core and `updateState`'s slice of it: every shape
    // `emitUnits` can still produce for a model with no §9.4 display unit.
    // The §4.5.11 `__sec` coefficient reader is not a unit file: it stays in
    // the prologue (below), where every unit file reaches it through `dev`.
    try std.testing.expectEqual(@as(usize, 2), o.names.len);
    for (o.names, o.unit_lo, o.unit_hi, 0..) |name, lo, hi, i| {
        // Tiling: `Output`'s invariant, and what lets the writer rebuild
        // device.zig as prologue ++ imports ++ tail with nothing dropped.
        if (i != 0) try std.testing.expectEqual(o.unit_hi[i - 1], lo);
        const decl = try std.testing.allocator.print("fn {s}(", .{name});
        defer std.testing.allocator.free(decl);
        // The range holds the declaration it is named for, and `unit_fn` points
        // at that declaration's keyword, where the writer splices `pub `,
        // without which `@import("u/<key>.zig").<key>` does not resolve.
        try std.testing.expect(std.mem.find(u8, o.text[lo..hi], decl) != null);
        try std.testing.expect(lo <= o.unit_fn[i] and o.unit_fn[i] < hi);
        const at = o.text[o.unit_fn[i]..];
        try std.testing.expect(std.mem.startsWith(u8, at, decl) or
            std.mem.startsWith(u8, at, "pub fn "));
    }
    // The tail after the last unit is the dispatcher, not more units.
    try std.testing.expect(std.mem.find(u8, o.text[o.unit_hi[o.unit_hi.len - 1]..], "pub fn eval(") != null);
    // The prologue before the first unit carries the types a unit file aliases.
    try std.testing.expect(std.mem.find(u8, o.text[0..o.unit_lo[0]], "pub const Model = struct {") != null);
    try std.testing.expect(std.mem.find(u8, o.text[0..o.unit_lo[0]], "__sec(") != null);
}

test "codegen: the unit prologue aliases the helper API and not its internals" {
    // `appendAliases` reads the same text `publish` does, so every helper is
    // aliased by construction. The `z` + uppercase clause is what keeps a
    // kernel file's private names out of the prologue; pin both sides.
    const gpa = std.testing.allocator;
    const has = std.mem.find;
    var str: std.ArrayList(u8) = .empty;
    defer str.deinit(gpa);
    try gen_kernel_text.appendAliases(&str, gpa, gen_kernel_text.str_txt);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try gen_kernel_text.appendAliases(&file, gpa, gen_kernel_text.file_txt);
    try std.testing.expect(has(u8, str.items, "const zScan = zh.zScan;\n") != null);
    try std.testing.expect(has(u8, file.items, "const zFOpen = zh.zFOpen;\n") != null);
    // str_scan.zig's `pub const ZScan` and `const zstd`, file_kernels.zig's
    // `fn zfIo` and `const zf_max`: public in h.zig, never named by an emitted
    // body, so aliasing them would be legal, unreferenced, and pure noise.
    try std.testing.expect(has(u8, str.items, "ZScan") == null);
    try std.testing.expect(has(u8, str.items, "zstd") == null);
    try std.testing.expect(has(u8, file.items, "zfIo") == null);
    try std.testing.expect(has(u8, file.items, "zf_max") == null);
}

test "codegen: every split unit file passes AstGen, hoist arrays included" {
    // A `u/<key>.zig` is the prelude ++ its unit, so a body local that shares a
    // prelude name is a shadowing error in the split (`--emit-so`) form alone.
    // `ln` keeps the diamond out of ifconv, so `y` is a two-assignment phi and
    // lands in the hoist array.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module hoist(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real k = 2.0;
        \\  real y;
        \\  analog begin
        \\    if (V(p, n) > 0.0)
        \\      y = ln(V(p, n) * k);
        \\    else
        \\      y = -V(p, n);
        \\    I(p, n) <+ y * y;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const o = try h.genOut(std.testing.allocator);
    const gpa = std.testing.allocator;
    try std.testing.expect(o.names.len != 0);
    try std.testing.expect(std.mem.find(u8, o.text, "var h0: [") != null);
    for (o.unit_lo, o.unit_fn, o.unit_hi) |lo, fn_at, hi| {
        // `zigbuild.writeTree`'s unit file.
        const file = try std.mem.concatWithSentinel(gpa, u8, &.{ o.prelude, o.text[lo..fn_at], "pub ", o.text[fn_at..hi] }, 0);
        defer gpa.free(file);
        var tree = try std.zig.Ast.parse(gpa, file, .{ .mode = .zig });
        defer tree.deinit(gpa);
        var zir = try std.zig.AstGen.generate(gpa, tree);
        defer zir.deinit(gpa);
        if (zir.hasCompileErrors()) std.debug.print("{s}\n", .{file});
        try std.testing.expect(!zir.hasCompileErrors());
    }
}

test "codegen: a laplace device's split unit files reach its __sec reader" {
    // ESPice's `.hdl` loader builds split: the core called `<unit>__sec`, a
    // unit file of its own, with no declaration in the core's file
    // ("use of undeclared identifier", GeneratedDeviceDoesNotCompile). The
    // reader now sits in device.zig's prologue, public, and every unit file
    // aliases it from `dev`; AstGen resolves every identifier, so it fails
    // on a unit file that names one it does not declare.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module vl2(p, n, cp, cn);
        \\  inout p, n, cp, cn;
        \\  electrical p, n, cp, cn;
        \\  parameter real num[0:2] = '{1.0, 0.0, 0.0};
        \\  parameter real den[0:2] = '{1.0, 1e-9, 0.0};
        \\  analog V(p, n) <+ laplace_nd(V(cp, cn), num, den);
        \\endmodule
    , &h);
    defer h.deinit();
    const o = try h.genOut(std.testing.allocator);
    const gpa = std.testing.allocator;
    try std.testing.expect(o.names.len != 0);
    const sec = "vl2__analog_op__laplace_nd__sec";
    // In device.zig's prologue, public, and no unit file of its own.
    try std.testing.expect(std.mem.find(u8, o.text[0..o.unit_lo[0]], "pub fn " ++ sec ++ "(") != null);
    for (o.names) |nm| try std.testing.expect(!std.mem.endsWith(u8, nm, "__sec"));
    try std.testing.expect(std.mem.find(u8, o.prelude, "const " ++ sec ++ " = dev." ++ sec ++ ";\n") != null);
    var named = false;
    for (o.unit_lo, o.unit_fn, o.unit_hi) |lo, fn_at, hi| {
        named = named or std.mem.find(u8, o.text[lo..hi], sec ++ "(model)") != null;
        const file = try std.mem.concatWithSentinel(gpa, u8, &.{ o.prelude, o.text[lo..fn_at], "pub ", o.text[fn_at..hi] }, 0);
        defer gpa.free(file);
        var tree = try std.zig.Ast.parse(gpa, file, .{ .mode = .zig });
        defer tree.deinit(gpa);
        var zir = try std.zig.AstGen.generate(gpa, tree);
        defer zir.deinit(gpa);
        if (zir.hasCompileErrors()) std.debug.print("{s}\n", .{file});
        try std.testing.expect(!zir.hasCompileErrors());
    }
    // The core reads the reader, so the split form exercised the alias.
    try std.testing.expect(named);
}

test "codegen: identical MIR yields a byte-identical file (determinism)" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h2);
    defer h2.deinit();
    try std.testing.expectEqualStrings(try h1.gen(std.testing.allocator), try h2.gen(std.testing.allocator));
}

test "codegen: adding a contribution appends to the core, it does not renumber" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n, m;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(m, n) <+ V(m, n) / r;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();

    const a = try h1.gen(std.testing.allocator);
    const b2 = try h2.gen(std.testing.allocator);
    // The first contribution is still `f0` and `eval` still stamps it from
    // `m.f0`. That is what `plan_core.plan`'s job-order numbering buys: the field
    // index of an existing target is insert-tolerant in the same sense
    // `ir/names.zig` makes a declaration name insert-tolerant, so `zig`'s
    // `TrackedInst` for the dispatcher does not churn on an unrelated edit.
    try std.testing.expect(std.mem.find(u8, a, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.find(u8, b2, "const c = m.f0;") != null);
    const ka = a[std.mem.find(u8, a, "inline fn zResidual(").?..];
    const kb = b2[std.mem.find(u8, b2, "inline fn zResidual(").?..];
    const na = std.mem.find(u8, ka, "    }\n").? + 6;
    const nb = std.mem.find(u8, kb, "    }\n").? + 6;
    try std.testing.expectEqualStrings(ka[0..na], kb[0..nb]);
}

test "codegen: §5.6.1.2 reactive split emits q(), §4.2.12 select stays lazy" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn q(comptime S: type") != null);
    // The reactive half is a SECOND field of the same core, reached by `q`:
    // the split survives the merge as two targets, not two declarations.
    try std.testing.expect(std.mem.find(u8, src, "fn cap__common__core(") != null);
    // §4.2.3/§4.2.12 laziness (proof.zig's CODEGEN OBLIGATION): the `ln` must
    // sit INSIDE the arm, never in a preceding `const`. Matching a bare `if (`
    // is deliberate: `?:` lowers to a CFG diamond (`lowerTernary`) and a
    // `select` renders as the expression `(if (c) a else b)`, and BOTH satisfy
    // the obligation. What must never happen is `.log()` ahead of the guard.
    const unit = src[std.mem.find(u8, src, "fn cap__common__core(").?..];
    const body = unit[0..std.mem.find(u8, unit, "\n}\n").?];
    const guard = std.mem.find(u8, body, "if (").?;
    const lg = std.mem.find(u8, body, "zLnD(").?;
    try std.testing.expect(lg > guard);
}

test "codegen: evalQ fuses both residuals onto ONE core call" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real r = 1e3 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) / r;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // `eval` and `q` survive untouched; the fusion is additive.
    try std.testing.expect(std.mem.find(u8, src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub fn q(comptime S: type") != null);
    const at = std.mem.find(u8, src, "pub fn evalQ(comptime S: type").?;
    const fused = src[at..][0..std.mem.find(u8, src[at..], "\n}\n").?];

    // The whole point: ONE core call for both halves. Two would make `evalQ`
    // exactly the `eval` + `q` it exists to replace.
    try std.testing.expect(std.mem.count(u8, fused, "@call(.always_inline, core, .{ S, xs, model, inst, sim })") == 1);
    // ...and it is hoisted ABOVE both halves: the resistive rows are `eval`'s
    // own `zResidual`, handed this core result.
    try std.testing.expect(std.mem.find(u8, fused, "@call(.always_inline, core, .{ S, xs, model, inst, sim })").? <
        std.mem.find(u8, fused, "zResidual(S, xs, m)").?);
    try std.testing.expect(std.mem.find(u8, fused, "struct { res: contract.Rows(Self, S), q: contract.Sites(Self, S) }") != null);
    // §5.6.1.2 the reactive half is the charge sites, read off the same core.
    try std.testing.expect(std.mem.find(u8, fused, "return .{ .res = zResidual(S, xs, m), .q = @as(contract.Sites(Self, S), .{ m.f") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {\n    const xs = zProbe(S, x);\n    return zResidual(S, xs, @call(") != null);
    // The one `ddt` site stamps +p and −n (§1.3.1.2).
    try std.testing.expect(std.mem.find(u8, src, "pub const n_q: usize = 1;") != null);
    try std.testing.expect(std.mem.find(u8, src, ".{ .site = 0, .row = .p, .sign = 1.0 },\n    .{ .site = 0, .row = .n, .sign = -1.0 },") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub const q_lte = [n_q]bool{ true };") != null);
}

test "codegen: a device with no reactive half gets no evalQ" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1e3 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Pairs with `q`: the contract rejects `evalQ` without one, so codegen
    // must not emit a fused entry point there is nothing to fuse.
    try std.testing.expect(std.mem.find(u8, src, "pub fn q(") == null);
    try std.testing.expect(std.mem.find(u8, src, "pub fn evalQ(") == null);
}

test "codegen: §5.8 control flow reconstructs into structured Zig" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real ron = 1.0 from (0:inf);
        \\  parameter real roff = 1e9 from (0:inf);
        \\  analog begin : body
        \\    real g;
        \\    g = 0.0;
        \\    if (V(p, n) > 0.5) g = 1.0 / ron; else g = 1.0 / roff;
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "if (") != null);
    try std.testing.expect(std.mem.find(u8, src, "} else {") != null);
    try std.testing.expect(std.mem.find(u8, src, "break :B") != null);
}

test "codegen: minmax tie derivatives use source-defined mask selection" {
    for ([_][]const u8{ "min", "$min", "max", "$max" }) |name| {
        const input = try std.testing.allocator.print(
            "module m(p,q); inout p,q; electrical p,q; analog I(p) <+ {s}(V(p),V(q)); endmodule",
            .{name},
        );
        defer std.testing.allocator.free(input);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, input, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        const call = if (std.mem.endsWith(u8, name, "min")) "zMin(zL(S, " else "zMax(zL(S, ";
        try std.testing.expect(std.mem.find(u8, src, call) != null);
        try std.testing.expect(std.mem.find(u8, src, "return a.lt(b).sel(a, b);") != null);
        try std.testing.expect(std.mem.find(u8, src, "return b.lt(a).sel(a, b);") != null);
    }
}

test "codegen: if-converted diamond emits an eager mask select in a strict unit" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module mix(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin : body
        \\    real g;
        \\    if (V(p, n) > 0.5) g = 2.0 * V(p, n); else g = 0.5 * V(p, n);
        \\    I(p, n) <+ g * exp(V(p, n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // root.zig runs this between lower and prove; the harness does the same.
    // The MIR is arena-owned, so the pass must append with the same arena.
    const n = try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null);
    try std.testing.expect(n >= 1);
    const src = try h.gen(std.testing.allocator);
    // exp(unbounded V) forfeits finiteness, so the unit is .strict, the
    // eager-sel license. Arms are plain arithmetic: mask form, no branch.
    try std.testing.expect(std.mem.find(u8, src, ".sel(") != null);
    // Lane-true mask: `V > 0.5` renders in S space as the swapped `lt`, not
    // as a `.val()` i64 round-trip.
    try std.testing.expect(std.mem.find(u8, src, ".lt(") != null);
    // The diamond is gone: nothing left for the relooper to label.
    try std.testing.expect(std.mem.find(u8, src, "break :B") == null);
}

test "codegen: a value shared by select arms is computed once, not once per use" {
    var h: Harness = undefined;
    // bsim2's vgeff shape: `e` is computed before the `if`, and after
    // conversion its only readers are select arms. Inlined per arm position
    // it would be four `exp` calls for the source's one.
    try Harness.run(std.testing.allocator,
        \\module sh(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin : body
        \\    real e, g;
        \\    e = exp(V(p, n));
        \\    if (V(p, n) > 0.5) g = e * e + e; else g = 0.5 * e;
        \\    I(p, n) <+ g;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expect(try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null) >= 1);
    const src = try h.gen(std.testing.allocator);
    const unit = src[std.mem.find(u8, src, "fn sh__").?..];
    const body = unit[0..std.mem.find(u8, unit, "\n}\n").?];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, ".exp()"));
}

test "codegen: a domain-guarded arm stays lazy through if-conversion" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lg(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null);
    const src = try h.gen(std.testing.allocator);
    // What this protects is §4.2.12 laziness, not a spelling: `ln` runs only
    // on the path `V > vmin` selects. The guard may come out as a lazy
    // `(if (c) a else b)` or as the CFG `if (c) { ... } else { ... }` that
    // ifconv keeps for a domain-restricted arm. Both pass; an eager `.sel(`
    // or a `.log()` outside the then-arm fails.
    // Scoped to the unit body: the emitted math prelude also spells `.log()`.
    const unit = src[std.mem.find(u8, src, "fn lg__").?..];
    const body = unit[0..std.mem.find(u8, unit, "\n}\n").?];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "zLnD("));
    const lg2 = std.mem.find(u8, body, "zLnD(").?;
    // The nearest `if (` before the `.log()` opens the arm holding it, and no
    // `else` between them makes that the THEN arm, the one `V > vmin` takes.
    const guard = std.mem.findLast(u8, body[0..lg2], "if (").?;
    try std.testing.expect(std.mem.find(u8, body[guard..lg2], "else") == null);
    try std.testing.expect(std.mem.find(u8, body[0..lg2], "model.vmin") != null);
    try std.testing.expect(std.mem.find(u8, body, ".sel(") == null);
    // And the proof accepted `ln` UNDER that guard: without it V <= 0 is
    // reachable and the unit would drop to `.strict`.
    try std.testing.expect(std.mem.find(u8, body, "@setFloatMode(.optimized)") != null);
}

test "codegen: a multi-use domain op under a guard keeps its CFG diamond" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ml(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin : body
        \\    real y;
        \\    y = 0.0;
        \\    if (V(p, n) > 0.0) begin : arm
        \\      real t;
        \\      t = ln(V(p, n));
        \\      y = t + 2.0 * t; // t shared: markSelectArms could not guard it
        \\    end
        \\    I(p, n) <+ y * 1.0e-3;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // The guard's evidence only survives conversion on exclusively-owned
    // slices; a shared `ln` result must refuse, or the model silently drops
    // to `.strict` (and an integer `/` in the same shape turns REJECTED).
    const n = try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null);
    try std.testing.expectEqual(@as(u32, 0), n);
    // Still compiles and proves through the CFG dominance path.
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "zLnD(") != null);
}

test "codegen: a speculated domain op runs on its safe argument off its guard (#81)" {
    // The same shape after `.speculate` (src/Compilation.zig runs it after a proof
    // that left the reads `.strict`): the branch is gone, and the checked ln
    // reads `V` only while `V > 0` holds, else ln's safe argument 1, so the
    // §4.3.2 report never fires from the arm the source did not run.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ml(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin : body
        \\    real y;
        \\    y = 0.0;
        \\    if (V(p, n) > 0.0) begin : arm
        \\      real t;
        \\      t = ln(V(p, n));
        \\      y = t + 2.0 * t;
        \\    end
        \\    I(p, n) <+ y * 1.0e-3;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null);
    try std.testing.expectEqual(@as(u32, 1), try ifconv.run(h.arena_state.allocator(), &h.mir, .speculate, null));
    const src = try h.gen(std.testing.allocator);
    const unit = src[std.mem.find(u8, src, "fn ml__").?..];
    const body = unit[0..std.mem.find(u8, unit, "\n}\n").?];
    const lg = std.mem.find(u8, body, "zLnD(S, zPick(S, ").?;
    // The guard is the branch's condition, and the fallback is `S.con(1.0)`.
    const guard_end = std.mem.find(u8, body[lg..], "S.con(1.0)").?;
    try std.testing.expect(std.mem.find(u8, body[lg..][0..guard_end], "zCmp(S, .lt, S.con(0.0)") != null or
        std.mem.find(u8, body[lg..][0..guard_end], "!= 0") != null);
    try std.testing.expect(std.mem.find(u8, body, "if (") == null or std.mem.find(u8, body, "} else {") == null);
}

test "codegen: a §5.6 potential contribution gets its own branch-current unknown" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module vs(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real dc = 1.0;
        \\  analog V(p, n) <+ dc;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // lowering only allocates `flow(a,b)` where the model PROBES I(a,b), so
    // codegen appends the unknown AFTER `nodes`, so existing indices hold.
    try std.testing.expect(std.mem.find(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub const u_kinds") != null);
    try std.testing.expect(std.mem.find(u8, src, ".sub(c));") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub const num_ports: usize = 2;") != null);
}

test "codegen: §4.6.4 two noise sources on one branch export TWO generators" {
    var h: Harness = undefined;
    // The clause's own shape: "multiple noise contributions to a single branch
    // are combined" (as `combined/noise_temperature_analysis.va` writes it).
    // Neither statement may overwrite the other's generator.
    try Harness.run(std.testing.allocator,
        \\module rnoise(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1000.0;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / rs;
        \\    I(p, n) <+ white_noise(1.6e-23 / rs, "thermal");
        \\    I(p, n) <+ flicker_noise(1e-20, 1.0, "flicker");
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // §4.6.4.6 each CALL is one generator, so the two rows carry distinct
    // dense `source` ids: two independent sources, not one shared.
    // §4.6.4.1/.2 the trailing `name` argument is a LABEL and rides out with
    // the row. Two calls sharing one name would still be two sources (the
    // clause combines them in the host's summary, not in the table), which is
    // why `source` is distinct here while `name` is free to repeat.
    try std.testing.expect(std.mem.find(u8, src, ".kind = .thermal, .source = 0, .name = \"thermal\" }") != null);
    try std.testing.expect(std.mem.find(u8, src, ".kind = .flicker, .source = 1, .name = \"flicker\" }") != null);
    // §4.6.4.1 before §4.6.4.2: the sources append in statement order, so the
    // table is stable across builds and a host may index it positionally.
    try std.testing.expect(
        std.mem.find(u8, src, ".kind = .thermal").? <
            std.mem.find(u8, src, ".kind = .flicker").?,
    );
}

test "codegen: §4.6.4 noisePsd is the model's own PSD, and a guarded one reads zero" {
    var h: Harness = undefined;
    // The shape EVERY series resistance in a real model card writes: the
    // generator lives inside `if (r > 0)`, and its power divides by that very
    // `r`. Computing `4kT/r` unconditionally evaluates it at r == 0: an
    // infinity that becomes a NaN the instant the collapsed branch gives it a
    // zero adjoint gain. It has to stay a core live-out, which `probeBody`
    // seeds `S.con(0.0)` and only the taken branch assigns.
    try Harness.run(std.testing.allocator,
        \\module rn(p, n, m);
        \\  inout p, n, m;
        \\  electrical p, n, m;
        \\  parameter real rs = 0.0;
        \\  parameter real ich = 1e-3;
        \\  analog begin
        \\    I(p, n) <+ white_noise(2.0 * 1.602176634e-19 * abs(ich), "shot");
        \\    if (rs > 0.0) begin
        \\      I(n, m) <+ V(n, m) / rs;
        \\      I(n, m) <+ white_noise(1.6e-23 / rs, "rs");
        \\    end else begin
        \\      V(n, m) <+ 0.0;
        \\    end
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The hook exists and is positional against `noise_gens`.
    const at = std.mem.find(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.find(u8, src, "pub const noise_gens").? < at);
    // Both powers come out of the core, NOT off a Jacobian and NOT inline:
    // §4.6.4.1 states the density as the call's argument, so the shot row is
    // `2q|I|` and the thermal row is `4kT/rs`: the same call, different
    // arguments, and only the model knows which.
    const body = src[at..];
    const ret = std.mem.find(u8, body, "return .{").?;
    try std.testing.expect(std.mem.find(u8, body[0..ret], "rn__common__core__noise(S, zVals(S, &x), model, inst, sim)") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body[ret .. ret + 120], ".white = m.f"));
    // Both powers are solve-invariant, so the core returns them as `setup`
    // roots, and `setup` divides by rs only on the `rs > 0` arm, leaving the
    // root at its zero seed otherwise: a guarded generator still reads zero.
    var k: usize = ret;
    while (std.mem.findPos(u8, body, k, ".white = m.f")) |i| {
        const f = body[i + ".white = m.f".len ..];
        const end = std.mem.findScalar(u8, f, '.').?;
        const decl = try std.testing.allocator.print("    .f{s} = zTo(S, 0x0, S.con(model.su.r[", .{f[0..end]});
        defer std.testing.allocator.free(decl);
        try std.testing.expect(std.mem.find(u8, src, decl) != null);
        k = i + 1;
        if (k > ret + 120) break;
    }
    const su = src[std.mem.find(u8, src, "pub fn setup(").?..];
    const div = std.mem.find(u8, su, "/ (model.rs)").?;
    try std.testing.expect(std.mem.findLast(u8, su[0..div], "if (").? < div);
    try std.testing.expect(std.mem.find(u8, su[0..div], "} else {") == null);
}

test "codegen: §4.6.4.3/.4 a noise table is exported sorted, with its own interpolation" {
    var h: Harness = undefined;
    // The two clauses' arguments are IDENTICAL in shape ("the meaning and
    // restrictions on the input are the same as for noise_table()"), and they
    // differ only in how the points are joined, so the difference has to be in
    // the exported table and nowhere else. Written descending, because
    // §4.6.4.3 makes sorting the simulator's job.
    try Harness.run(std.testing.allocator,
        \\module ntab(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ noise_table('{1e6, 1e-24, 1.0, 1e-18});
        \\    I(p, n) <+ noise_table_log('{1.0, 1e-18, 1e6, 1e-24});
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Ascending, whichever order the model wrote them in, and each table keeps
    // the interpolation of the FUNCTION that declared it. The literals are
    // `fmtF64`'s, which is every other constant in the emitted device too.
    const p18 = "0.000000000000000001"; // 1e-18
    const p24 = "0.000000000000000000000001"; // 1e-24
    try std.testing.expect(std.mem.find(u8, src, ".{ .interp = .linear, .points = &.{ .{ 1.0, " ++ p18 ++ " }, .{ 1000000.0, " ++ p24 ++ " } } }") != null);
    try std.testing.expect(std.mem.find(u8, src, ".{ .interp = .log, .points = &.{ .{ 1.0, " ++ p18 ++ " }, .{ 1000000.0, " ++ p24 ++ " } } }") != null);
    // One exported kind for both clauses, each row naming its own table, and
    // both independent generators (§4.6.4.6: two calls, two sources).
    try std.testing.expect(std.mem.find(u8, src, ".kind = .table, .source = 0, .table = 0 }") != null);
    try std.testing.expect(std.mem.find(u8, src, ".kind = .table, .source = 1, .table = 1 }") != null);
    // `noise_tables` is read by `noise_gens`, so it has to be declared first.
    try std.testing.expect(
        std.mem.find(u8, src, "pub const noise_tables").? <
            std.mem.find(u8, src, "pub const noise_gens").?,
    );
    // The parametric half of a table row is ZERO, or a host that adds
    // `white + flicker/f^ef` to the table's answer would double-count.
    // §4.6.4.6's coefficient is 1 on both: each table is contributed with no
    // factor, so the row scales its own spectrum by exactly one.
    const at = std.mem.find(u8, src, "pub fn noisePsd(").?;
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, src[at..], ".{ .white = 0, .coeff = 1 }, // noise_tables["),
    );
}

test "codegen: §4.6.4.3 an array-parameter table exports the card's knots, a literal one does not" {
    // A.8.2's `noise_table_input_arg` names `parameter_identifier` FIRST, and
    // §3.4 makes a parameter's value the model card's. So the comptime
    // `noise_tables` can only be the DECLARED DEFAULT and the card's answer is
    // the extra hook, which must not appear on a device that has no
    // parameter in any table, or every host of every such device would be
    // obliged to read something `noise_tables` already told it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module nparam(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real tbl[0:3] = '{1e6, 1e-24, 1.0, 1e-18};
        \\  analog I(p, n) <+ noise_table(tbl);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Sorted at compile time on the DEFAULTS, so `noise_tables` keeps the
    // invariant `contract.validate` enforces...
    try std.testing.expect(std.mem.find(u8, src, ".points = &.{ .{ 1.0, 0.000000000000000001 }, .{ 1000000.0, 0.000000000000000000000001 } }") != null);
    // ...and the hook returns the same two knots in the same order, reading
    // the card, with the run-time sort a reordering card would need.
    const at = std.mem.find(u8, src, "pub fn noiseTablePoints(model: *const Model) [2][2]f64 {").?;
    const end = std.mem.findPos(u8, src, at, "\n}\n").?;
    const body = src[at..end];
    try std.testing.expect(std.mem.find(u8, body, ".{ model.tblZ5b2Z5d, model.tblZ5b3Z5d }") != null);
    try std.testing.expect(std.mem.find(u8, body, ".{ model.tblZ5b0Z5d, model.tblZ5b1Z5d }") != null);
    try std.testing.expect(std.mem.find(u8, body, "contract.sortNoiseTable(pts[0..2]);") != null);
    // The default's order is the EXPORT's order: `noise_tables[k]` and the
    // hook's k-th pair are the same knot, so the sort permuted both.
    try std.testing.expect(std.mem.find(u8, body, ".{ model.tblZ5b2Z5d, model.tblZ5b3Z5d }").? <
        std.mem.find(u8, body, ".{ model.tblZ5b0Z5d, model.tblZ5b1Z5d }").?);
    // The row carries its own sorted copy (`contract.noiseTable`, ESPice #9):
    // the declared defaults until `derive`, which refreshes it after the card.
    try std.testing.expect(std.mem.find(u8, src, "noise_table_points__: [2][2]f64 = .{ .{ 1.0, 0.000000000000000001 }, .{ 1000000.0, 0.000000000000000000000001 } },") != null);
    try std.testing.expect(std.mem.find(u8, src, "    model.noise_table_points__ = noiseTablePoints(model);\n") != null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module nlit(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table('{1.0, 1e-18, 1e6, 1e-24});
        \\endmodule
    , &h2);
    defer h2.deinit();
    const lit = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, lit, "noiseTablePoints") == null);
    try std.testing.expect(std.mem.find(u8, lit, "noise_table_points__") == null);
}

test "codegen: §4.6.4.6 each use of a shared generator exports its own coefficient" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module shared(a, b, c, d);
        \\  inout a, b, c, d;
        \\  electrical a, b, c, d;
        \\  parameter real pwr = 1e-18;
        \\  real nz;
        \\  analog begin
        \\    nz = white_noise(pwr, "shared");
        \\    V(a, b) <+ 2.0 * nz;
        \\    V(d, c) <+ 3.0 * nz;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // ONE generator (both rows carry `.source = 0`) with TWO coefficients.
    // Without them both rows report the raw 1e-18 and a host computes this
    // module's output noise 4x and 9x low. Both are voltages in series
    // with their branch (§4.6.4.1), so each coefficient carries the branch
    // row's sign, `V(hi,lo) − <value>`: `-(...)`.
    const at = std.mem.find(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.find(u8, src[at..], ".coeff = -(2") != null);
    // §1.3.1.2: `V(d,c)` drives the same branch as `V(c,d)` with the sign
    // flipped, and the SIGN is what separates correlation from
    // anti-correlation, so it has to survive into the export.
    try std.testing.expect(std.mem.find(u8, src[at..], ".coeff = -(-3") != null);
}

test "codegen: §4.6.4.6 a generator no single factor describes keeps coefficient 1" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sq(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  real nz;
        \\  analog begin
        \\    nz = white_noise(1e-18);
        \\    I(a, b) <+ nz * nz;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // A generator squared is not a linear source, so there is no coefficient
    // to report and the row keeps 1 rather than inventing one.
    const at = std.mem.find(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.find(u8, src[at..], ".coeff = 1") != null);
}

test "codegen: §4.6.4.6 one tabulated source on two branches is one table" {
    var h: Harness = undefined;
    // The clause's Example 1 shape with a §4.6.4.4 source: "Perfectly
    // correlated noise is generated by using the output of one noise function
    // for more than one noise source." One call is one generator, so the two
    // rows share a `source` and must share the TABLE too, or the export
    // describes one generator with two copies of its own spectrum.
    try Harness.run(std.testing.allocator,
        \\module nshare(a, b, c);
        \\  inout a, b, c;
        \\  electrical a, b, c;
        \\  real nt;
        \\  analog begin
        \\    nt = noise_table_log('{1.0, 1e-18, 1e6, 1e-24});
        \\    I(a, b) <+ nt;
        \\    I(b, c) <+ 2.0 * nt;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, ".interp = ."));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, ".source = 0, .table = 0 }"));
}

test "codegen: §4.6.3 an ac_stim exports its phasor and no noise generator" {
    var h: Harness = undefined;
    // The whole of the export in one module: the stimulus reaches the
    // contribution through a VARIABLE (which is how every fixture writes it),
    // the phase is a quadrature one where `mag*cos(phase)` is 6.1e-17, and the
    // model also declares a real noise generator so the two tables are
    // observably separate.
    try Harness.run(std.testing.allocator,
        \\module stim(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real amp = 2.0;
        \\  real s;
        \\  analog begin
        \\    s = ac_stim("xf", amp, 1.5707963267948966);
        \\    I(p, n) <+ V(p, n) * 1e-3 + 3.0 * s;
        \\    I(p, n) <+ white_noise(1e-18);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // §4.6.3 is not §4.6.4: the stimulus has its own table and puts no row in
    // `noise_gens`, which would be a generator the model never declared.
    try std.testing.expect(std.mem.find(u8, src, ".name = \"xf\" }") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "contract.NoiseGen(Self){"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "contract.AcGen(Self){"));
    // One call is one source: the variable reaching two places (the value and
    // the contribution) must not become two rows.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, ".name = \"xf\" }"));
    // The magnitude is a PARAMETER, so it cannot be comptime data: `acStim`
    // reads the card. And §4.6.4.6's per-use factor folds into it (a phasor
    // scales exactly), or a host is low by 3 on this source.
    const at = std.mem.find(u8, src, "pub fn acStim(").?;
    try std.testing.expect(std.mem.find(u8, src[at..], "(model.amp) * (3") != null);
    // Polar, not rectangular: `cos(π/2)` is 6.1e-17 and a stimulus that has
    // been through a complex conversion here is that far out of quadrature
    // before the host has done anything.
    try std.testing.expect(std.mem.find(u8, src[at..], ".phase = 1.5707963267948966") != null);
    // "xf" is no Table 4-21 small-signal kind, so the residual's stimulus is
    // live in a small-signal analysis the host labels "xf" (VD-109), read
    // through the GPU-safe Table 9-28 channel the Model row now carries.
    try std.testing.expect(std.mem.find(u8, src, "    analysis_name_idx__: u32 = 0,") != null);
    try std.testing.expect(std.mem.find(u8, src, "((sim.kind == .ac or sim.kind == .noise) and std.mem.eql(u8, contract.hostString(model.analysis_name_idx__, inst.analysis_name), \"xf\"))") != null);
}

test "Harness.run: a source lowering refuses frees what it lowered, and keeps the refusal's code" {
    // Oracle: std.testing.allocator's leak check. A caller that `try`s
    // `run` never reaches its `defer deinit`, so a refused source must
    // leave nothing allocated; `deinit` after it must still be safe (no
    // double free), and the refusal's code survives for the caller.
    // §4.4 Table 4-16: `I(p, p)` is an error (E0315).
    const src =
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p, p) <+ V(p);
        \\endmodule
    ;
    var h: Harness = undefined;
    try std.testing.expectError(error.DiagnosticsReported, Harness.run(std.testing.allocator, src, &h));
    try std.testing.expectEqual(@as(?@import("diag").Code, .E0315), h.first_error);
    var h2: Harness = undefined;
    try std.testing.expectError(error.DiagnosticsReported, Harness.run(std.testing.allocator, src, &h2));
    h2.deinit();
}

test "codegen: §4.6.4 a generator VerA cannot export refuses the device" {
    // Both halves of the same rule: a `noise_gens` row that cannot be written
    // must take the DECL with it. Silently dropping the row would tell a host
    // the model declares no such noise, which is a PSD it can never ask for;
    // and `@compileError` is how codegen refuses (see `f64Expr`/E0515).
    const cases = [_][]const u8{
        // §1.3.1.1 a ground-ground branch has no row and no column (E0520):
        // two `ground` nets, one node. Not `I(g, g)`, which §4.4 Table
        // 4-16 makes an error of its own however `ground` is exempted.
        \\module ngnd(p);
        \\  inout p;
        \\  electrical p;
        \\  ground g1, g2;
        \\  electrical g1, g2;
        \\  analog begin
        \\    I(p) <+ V(p) * 1e-3;
        \\    I(g1, g2) <+ white_noise(1e-20);
        \\  end
        \\endmodule
        ,
        // §4.6.4.3 "Each frequency value must be unique" (E0519).
        \\module ndup(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table('{1.0, 1e-18, 1.0, 1e-24});
        \\endmodule
        ,
        // §4.6.4.3 pairs, not an odd tail (E0519).
        \\module nodd(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table('{1.0, 1e-18, 10.0});
        \\endmodule
        ,
        // NOT here: §4.6.4.3's FILE form. Its name "shall be constant", so
        // `Lower.readNoiseTableFile` reads the pairs at compile time and the
        // table it produces is indistinguishable from the vector form's. A
        // file that cannot be read is a lowering error on the .va, which never
        // reaches codegen at all.
        //
        // Nor an array parameter: `noise_tables` carries its defaults and
        // `noiseTablePoints` the card (the test after this one).
        // §4.6.4.4 interpolates log(power), and log(0) is not on the line.
        \\module nlog0(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table_log('{1.0, 0.0, 1e6, 1e-24});
        \\endmodule
        ,
    };
    for (cases) |case| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, case, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.find(u8, src, "pub const noise_gens = @compileError(\"LRM 4.6.4:") != null);
        // And no half-written table beside it.
        try std.testing.expect(std.mem.find(u8, src, "pub const noise_tables") == null);
        try std.testing.expect(std.mem.find(u8, src, "pub fn noisePsd(") == null);
    }
}

test "codegen: §5.6.7 indirect contribution is a nullor row, ASYMMETRIC-safe" {
    var h: Harness = undefined;
    // Deliberately asymmetric: probe − equation = V(pin,nin) − 2*V(out).
    // The mirrored row (equation − probe) is invisible on the textbook opamp
    // (`V(pin,nin) == 0`), so the fixture that pins the sign has to be one
    // whose two sides differ.
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog V(out) : V(pin, nin) == 2.0 * V(out);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The source current is a solver unknown; the KCL stamps are its only
    // occurrence outside its own row (a nullor).
    try std.testing.expect(std.mem.find(u8, src, "flowZ28outZ2cgndZ29, // branch flow") != null);
    try std.testing.expect(std.mem.find(u8, src, "res[@intFromEnum(U.flowZ28outZ2cgndZ29)] = zRow(S, .flowZ28outZ2cgndZ29, c);\n") != null);
    // ... and NOT the direct-contribution row `V(hi,lo) − c`.
    try std.testing.expect(std.mem.find(u8, src, ".sub(c));") == null);

    // THE trap: the row must be a function of `x`, or the host's dual-number
    // Jacobian has a zero column and Newton can never move the source.
    const key = "fn amp__common__core(comptime S: type, x: anytype";
    try std.testing.expect(std.mem.find(u8, src, key) != null);
    const unit = src[std.mem.find(u8, src, key).?..];
    const body = unit[0..std.mem.find(u8, unit, "\n}\n").?];
    // probe − equation, in that order.
    const probe_at = std.mem.find(u8, body, "U.pin").?;
    // `2.0 * V(out)` reaches the constant through `scale`, not through a
    // second dual: the derivative-free side of a product never becomes an S.
    const eqn_at = std.mem.find(u8, body, "scale(2.0)").?;
    try std.testing.expect(std.mem.find(u8, body, ".sub(") != null);
    try std.testing.expect(probe_at < eqn_at);
}

test "codegen: §5.6.7.1 two indirect contributions to one branch get one source each" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module two(p, n, c1, c2);
        \\  inout p, n, c1, c2;
        \\  electrical p, n, c1, c2;
        \\  analog begin
        \\    V(p, n) : V(c1) == V(p, n);
        \\    V(p, n) : V(c2) == 2.0 * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Two sources ⇒ two currents ⇒ two DISTINCT U members (a shared name would
    // be a duplicate enum field, which the Zig parser cannot catch).
    try std.testing.expect(std.mem.find(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.find(u8, src, "flowZ28pZ2cnZ29Z231, // branch flow") != null);
    // Two targets ⇒ two distinct core fields ⇒ two rows in `eval`. (`ir/names.zig`'s
    // group-local ordinal keys the second unit's §4.5 state and proof verdict.)
    try std.testing.expect(std.mem.find(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.find(u8, src, "const c = m.f1;") != null);
}

test "codegen: §5.10.5 only a `timer` module gets a nextBreakpoint hook" {
    // The hook is OPTIONAL in lib/contract.zig, and emitting it
    // for a module with no timer would claim a schedule that does not exist:
    // the host reads "no breakpoints ever" and stops asking. `transition` is the
    // trap case: it is stateful and discontinuity-adjacent, but nothing about it
    // says WHERE a timepoint goes, only how fast the value moves.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.find(u8, src, "nextBreakpoint") == null);
}

test "codegen: §5.10.5 a timer whose start is a solved quantity emits NO hook" {
    // `nextBreakpoint` gets `*const Model` and no `Instance`, so the schedule
    // has to be a function of the parameters. A start_time read off the solution
    // is not, and there is no honest answer to give: a guessed one either hangs
    // the transient walk (an answer at or before `t`) or moves an edge. Silence
    // degrades to LTE step control, which is where every device is today.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fired;
        \\  analog begin
        \\    @(timer(V(p, n), 1e-9)) fired = fired + 1;
        \\    I(p, n) <+ fired;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "__next") != null); // the timer IS compiled
    try std.testing.expect(std.mem.find(u8, src, "nextBreakpoint") == null);
    // §5.10.3.3 but the LIVE schedule is: `updateState` re-arms `__next` from
    // the start_time, so an Instance-reading hook can answer what this cannot.
    try std.testing.expect(std.mem.find(u8, src, "pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64") != null);
}

test "codegen: §4.5 operator state is keyed to the stable unit id" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real td = 1e-9 from (0:inf);
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, td, td);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "tr__analog_op__transition__from: f64 = 0.0") != null);
    try std.testing.expect(std.mem.find(u8, src, "tr__analog_op__transition__t0: f64 = 0.0") != null);
    // The operator's input is a core field, not a declaration of its own; the
    // state field carries `ir/names.zig`'s key.
    try std.testing.expect(std.mem.find(u8, src, "zTransition(zL(S, ") != null);
    try std.testing.expect(std.mem.find(u8, src, "const m = tr__common__core__state(S, zVals(S, &x), model, inst, sim);") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub fn updateState(") != null);
    // `updateState`'s slice returns the operator input alone: the residual
    // stays in the core, and the accepted step never pays for it.
    const at = std.mem.find(u8, src, "fn tr__common__core__state(").?;
    const sig = src[at..std.mem.findPos(u8, src, at, "} {").?];
    try std.testing.expect(std.mem.find(u8, sig, "f0:") != null);
    try std.testing.expect(std.mem.find(u8, sig, "f1:") == null);
    try std.testing.expect(std.mem.find(u8, src, "pub const State = struct {") != null);
}

test "codegen: §4.5.11 laplace_nd emits a real filter, not a compile error" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lp(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ laplace_nd(V(p, n), '{1.0}, '{1.0, 1.0});
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "@compileError") == null);
    try std.testing.expect(std.mem.find(u8, src, "laplace_nd") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub fn updateState(") != null);
    // The cascade's `__sec(model)` call is the only Model read in this module,
    // so the unit's parameter must stay named, not `_`.
    try std.testing.expect(std.mem.find(u8, src, "__sec(model)") != null);
    try std.testing.expect(std.mem.find(u8, src, "core(comptime S: type, x: anytype, model: *const Model") != null);
}

test "codegen: a non-const analog-operator control argument is a LOUD compile error" {
    // Unsupported constructs must be loud, never a silent substitute value
    // (a silent 0 corrupts the residual). §4.5.14 requires control arguments
    // to be constant.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, V(p, n), 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "@compileError") != null);
}

test "codegen: §5.4.3 I(<p>) is a solver unknown pinned to the KCL sum at p" {
    var h: Harness = undefined;
    // §5.4.3's own diode example shape: the probed port also carries a `ddt`
    // contribution, so a DC-only port current would be silently wrong in tran.
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real cj = 1e-12;
        \\  real m;
        \\  analog begin
        \\    I(a, c) <+ 1e-3 * V(a, c) + ddt(cj * V(a, c));
        \\    m = I(<a>);
        \\    I(a, c) <+ 1e-9 * m;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Its own unknown, appended after the ports so `num_ports` is untouched,
    // and classified a CURRENT by the existing `flow(` predicate.
    try std.testing.expect(std.mem.find(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.find(u8, src, "flowZ28Z3caZ3eZ29, // branch flow") != null);

    // SIGN: `I(p,n) <+ c` stamps `+c` at hi, so res[a] is the current leaving
    // node a INTO the module, which is exactly §5.4.3's "flow into a port".
    // Hence `x − res[a]`, not `x + res[a]`.
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = zRow(S, .flowZ28Z3caZ3eZ29, x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(res[@intFromEnum(U.a)]));",
    ) != null);
    // THE REACTIVE HALF: the one charge site stamps `−q_a` on the same row,
    // so the total residual is x − (I_dc + d/dt q_a).
    try std.testing.expect(std.mem.find(
        u8,
        src,
        ".{ .site = 0, .row = .flowZ28Z3caZ3eZ29, .sign = -1.0 },",
    ) != null);
    // The row is emitted AFTER the contribution stamps it reads.
    const stamp_at = std.mem.find(u8, src, "res[@intFromEnum(U.a)].add(c)").?;
    const row_at = std.mem.find(u8, src, "= zRow(S, .flowZ28Z3caZ3eZ29, x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(").?;
    try std.testing.expect(stamp_at < row_at);
}

test "codegen: a port whose only branch goes to ground still gets its unknown" {
    var h: Harness = undefined;
    // The self-referential form: I(p) <+ I(<p>) + V(p). Nothing else drives p.
    try Harness.run(std.testing.allocator,
        \\module g(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ I(<p>) + V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "flowZ28Z3cpZ3eZ29, // branch flow") != null);
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3cpZ3eZ29)] = zRow(S, .flowZ28Z3cpZ3eZ29, x[@intFromEnum(U.flowZ28Z3cpZ3eZ29)].sub(res[@intFromEnum(U.p)]));",
    ) != null);
    // No reactive part anywhere ⇒ no q() at all, so no port row is missing.
    try std.testing.expect(std.mem.find(u8, src, "pub fn q(") == null);
}

test "codegen: the `U` block is the SPELLING contract — all four name kinds, verbatim" {
    var h: Harness = undefined;
    // `node_voltages` is one string key space over four different kinds of name,
    // and only one of them has a source spelling. The KEY is lowering's private
    // business, but the spelling is not: it reaches the user three times over:
    // as an emitted `U` member (here), as the identifier a `//! bias`/`//! sweep`
    // line has to write (tb.zig's `unknownName`, pinned in its own test), and as
    // the name every diagnostic over an unknown prints. So it is pinned as the
    // whole block, byte for byte, and not one `indexOf` per kind: an insertion,
    // a reorder or a re-escape is a change to the host's ABI and to every
    // fixture that biases an unknown, and each of those is invisible to a
    // substring search.
    //
    // Ports first, then §3.6.3 internal nets, then §5.4.2/§5.4.3 flows: the
    // order `emitTopology` documents, which is also `num_ports`' meaning.
    // `naming.sanitize` is what makes `b[0]` and `flow(p,n)` legal Zig, and
    // `isValidId` leaves `p` and `n` alone.
    try Harness.run(std.testing.allocator,
        \\module m(p, b);
        \\  inout p;
        \\  inout [0:1] b;
        \\  electrical p, n;
        \\  electrical [0:1] b;
        \\  real x;
        \\  analog begin
        \\    x = I(p, n);
        \\    I(p, n) <+ x + I(<p>);
        \\    I(b[0], b[1]) <+ V(b[0], b[1]);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src,
        \\pub const U = enum(u8) {
        \\    p, // port
        \\    bZ5b0Z5d, // port
        \\    bZ5b1Z5d, // port
        \\    n, // internal
        \\    flowZ28pZ2cnZ29, // branch flow
        \\    flowZ28Z3cpZ3eZ29, // branch flow
        \\};
    ) != null);
}

test "codegen: §5.9 a loop the unit re-runs is not read out of the shared core" {
    var h: Harness = undefined;
    // Two units both slice the loop, so `plan_core.plan` wants to hoist it, but
    // each also has private values inside it, so each re-materializes the loop.
    // Reading the hoisted counter and exit condition there is reading their
    // FINAL values, and the re-materialized loop then runs zero times.
    try Harness.run(std.testing.allocator,
        \\module l(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i;
        \\  real a, b;
        \\  analog begin
        \\    a = 0.0;
        \\    b = 0.0;
        \\    for (i = 1; i <= 5; i = i + 1) begin
        \\      a = a + i;
        \\      b = b + i * 2;
        \\    end
        \\    I(p, n) <+ a * V(p, n);
        \\    I(p) <+ b * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // `genDisplay`, not `gen`: the core emits the loop where its values are
    // computed, so only §9.4 `display`, which opens with `const c = core(...)`,
    // consumes the §5.9 `loop_recompute` fixpoint.
    const src = try h.genDisplay(std.testing.allocator);
    // A `while (true)` body must not read `c.f<N>`: that is the exit state.
    var rest = src;
    while (std.mem.find(u8, rest, "L")) |_| {
        const at = std.mem.find(u8, rest, ": while (true)") orelse break;
        const end = std.mem.findPos(u8, rest, at, "\n    }") orelse rest.len;
        try std.testing.expect(std.mem.find(u8, rest[at..end], "c.f") == null);
        rest = rest[end..];
    }
    // The residual half of the guarantee, stated structurally: the merged core
    // reads no cache, so a `c.f` cannot appear in it anywhere, in or out of a
    // loop. This is what makes the hazard impossible rather than merely absent.
    const core_at = std.mem.find(u8, src, "fn l__common__core(").?;
    const core_end = std.mem.findPos(u8, src, core_at, "\n}\n").?;
    try std.testing.expect(std.mem.find(u8, src[core_at..core_end], "c.f") == null);
}

test "codegen: §9.4 display tasks are void by default and print on request" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real g = 2.0;
        \\  analog begin
        \\    $strobe("g=%g n=%5d s=%s", g, 42, "x");
        \\    $write("no newline");
        \\    $error("bad");
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // A DEVICE never prints: no sink, nothing that blocks a GPU backend.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, dev, "std.debug.print") == null);
    try std.testing.expect(std.mem.find(u8, dev, "pub fn display(") == null);

    // The EXECUTABLE does, with §9.4.3 conversions translated and the operands
    // sliced in (a missing slice renders every one of them as `S.con(0.0)`).
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, exe, "pub fn display(") != null);
    // `%g` is a §9.4.3 Table 9-23 REAL conversion, so it composes its own
    // field through `str_real.zCReal` and arrives as `{s}`; `%5d` is the
    // documented zPadInt detour and `%s` is Zig's own verb.
    try std.testing.expect(std.mem.find(u8, exe, "g={s} n={s:>5} s={s}\\n") != null);
    try std.testing.expect(std.mem.find(u8, exe, "zCReal(&zb0, (S.con(model.g)).val(), 'g', 0, 0, -1)") != null);
    // §9.4.1 `$write` is the one that does not end the line.
    try std.testing.expect(std.mem.find(u8, exe, "\"no newline\"") != null);
    // §9.7.3 the severity is a prefix, not something a reader must infer,
    // and the moment (`zWhen`) sits between it and the message.
    try std.testing.expect(std.mem.find(u8, exe, "\"ERROR: \", .{}); zWhen(sim.t, 1); std.debug.print(\" bad") != null);
    // No `$debug`/`$fdebug`: one pass, no `pass` parameter.
    try std.testing.expect(std.mem.find(u8, exe, "SayPass") == null);
}

test "codegen: §9.5.9 `$fdebug` and `$debug` run on every pass but the accepted one" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module fd(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer f, g;
        \\  analog initial f = $fopen("a.log", "w");
        \\  analog begin
        \\    $fdebug(f, "x=%g", V(p, n));
        \\    $debug("x=%g", V(p, n));
        \\    $fwrite(f, "y");
        \\    g = $fopen("b.log", "r");
        \\    $strobe("s");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, exe, "pub fn displayPass(") != null);
    try std.testing.expect(std.mem.find(u8, exe, "displayPass(S, x, model, inst, sim, .all);") != null);
    try std.testing.expect(std.mem.find(u8, exe, ", comptime pass: contract.SayPass)") != null);
    // §5.2.1 the analog initial block's open runs once, at the first iterate.
    try std.testing.expect(std.mem.find(u8, exe, "(if (zFinish == 0 and (pass == .all or (pass == .iteration and sim.iteration == 1))) zFKeep(") != null);
    // `$fdebug` and `$debug`, then `$fwrite`, the main block's `$fopen` (its
    // latch otherwise) and `$strobe`.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, exe, "(if (zFinish == 0 and (pass != .accepted)) "));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, exe, "(if (zFinish == 0 and (pass != .iteration)) "));
    try std.testing.expect(std.mem.find(u8, exe, " else inst.zf__.res__") != null);
    // A device drops every §9.5 call: no passes.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, dev, "displayPass") == null);
}

test "codegen: §9.7.3 a `$fatal` alone still runs on every iterate" {
    // "$fatal terminates the simulation without checking whether the
    // iteration would be rejected": the unit runs in passes for it even
    // with no `$debug` or `$fdebug` beside it, and a vetoed iterate
    // performs it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module f(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    if (V(p, n) > 0.5) $fatal(1, "too high");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, exe, "pub fn displayPass(") != null);
    try std.testing.expect(std.mem.find(u8, exe, "(if (zFinish == 0 and (pass != .accepted)) ") != null);
}

test "codegen: §9.4.6 a display task under an `if` prints inside its arm" {
    // A guarded display call does not dominate the end-of-block chain root,
    // and an unchained call is dead code the unit slice drops. Lowering carries
    // it through an SSA place written in the arm, so the call keeps its CFG
    // position and the phi keeps it live.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module c(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    if (V(p, n) > 0.5) $strobe("hi");
        \\    else $strobe("lo");
        \\    $strobe("always");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const exe = try h.genDisplay(std.testing.allocator);
    const at = std.mem.find(u8, exe, "fn c__display__tasks(").?;
    const body = exe[at..std.mem.findPos(u8, exe, at, "\n}\n").?];
    // All three reach the output...
    for ([_][]const u8{ "\"hi\\n\"", "\"lo\\n\"", "\"always\\n\"" }) |lit|
        try std.testing.expect(std.mem.find(u8, body, lit) != null);
    // ...and the two guarded ones are still GUARDED: each sits after an `if`
    // and before the unconditional one, which is emitted at the block's end.
    const hi = std.mem.find(u8, body, "\"hi\\n\"").?;
    try std.testing.expect(std.mem.findLast(u8, body[0..hi], "if (") != null);
    try std.testing.expect(hi < std.mem.find(u8, body, "\"always\\n\"").?);
    // A DEVICE still prints nothing at all (W0850 covers the whole family).
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, dev, "std.debug.print") == null);
}

test "codegen: §9.5 a descriptor is an i64 in the DEVICE too, not only in the executable" {
    // `callee.ty` types the descriptor-returning §9.5 calls `.int`, so
    // in a device their slot is `i64` and `emitFileCallDropped` must write an
    // integer zero, not `S.con(0.0)`; otherwise the host's build fails on
    // generated Zig. `fd` feeds the residual on purpose: an unread descriptor
    // gets no slot. The suite compiles every fixture with `.display = .emit`,
    // so only this test reaches the `.drop` path.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module fdev(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fd;
        \\  analog begin
        \\    fd = $fopen("nope.txt");
        \\    I(p, n) <+ V(p, n) * (fd + 1);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // §9.5.1 "a zero is returned for the mcd or fd" as an INTEGER. A device has
    // no host file table, so zero is the answer and not a stub.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, dev, ": i64 = @as(i64, 0);") != null);
    try std.testing.expect(std.mem.find(u8, dev, ": i64 = S.con(") == null);
    // No kernel came with it: `buildPrelude` gates the descriptor table on
    // `display == .emit`, and a call to `zFOpen` here would not resolve.
    try std.testing.expect(std.mem.find(u8, dev, "zFOpen") == null);

    // The printing artifact opens the file for real, in the display unit, and
    // latches the descriptor; the core's `fd` (the one the residual and
    // `updateState` see) is that latch, not the device's zero.
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, exe, "zFKeep(") != null);
    try std.testing.expect(std.mem.find(u8, exe, ": i64 = inst.zf__.res__") != null);
}

test "codegen: §9.4 a display unit that reads an operator input opens the cache" {
    // The display unit is the one unit not folded into the core, and an
    // operator's input is not a `mark`ed operand, so a `c.f*` rendered for it
    // needs its own `const c = core(...)` above it. Same shape for
    // ddt/transition/slew/laplace.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dop(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    $strobe("y=%g", transition(V(p, n), 0.0, 1n, 1n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const exe = try h.genDisplay(std.testing.allocator);
    const at = std.mem.find(u8, exe, "zLw(S, 0x3, c.f").?;
    const open = std.mem.findLast(u8, exe[0..at], "const c = @call(.always_inline, core, .{ S, x, model, inst, sim });");
    const head = std.mem.findLast(u8, exe[0..at], "\nfn ") orelse 0;
    try std.testing.expect(open != null and open.? > head);
}

test "codegen: §2.6.1 an integer literal keeps all 64 bits" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module big(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer k;
        \\  analog begin
        \\    k = 4607182418800017408;
        \\    I(p, n) <+ V(p, n) * k;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The integer side of the product carries no derivative, so it folds and
    // arrives as the f64 the multiply needs. `fmtF64` is `{d}`, which is the
    // shortest representation that ROUND-TRIPS: 4607182418800017400.0 parses
    // back to exactly 4607182418800017408, and every literal in every emitted
    // device already rests on that. What must not happen is the value changing.
    try std.testing.expect(std.mem.find(u8, src, "scale(4607182418800017400.0)") != null);
    try std.testing.expectEqual(
        @as(f64, 4607182418800017408),
        try std.fmt.parseFloat(f64, "4607182418800017400.0"),
    );
    // `0.0 * k` would fold the contribution away entirely, which is why the
    // multiplicand here is a probe: the literal has to reach the device.
}

test "codegen: §3.2 the three sites that impose the 32-bit integer width agree" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer big = 2147483647 + 1;
        \\  parameter integer chained = big + 1;
        \\  localparam integer sh = 1 << 31;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) * (big + 1);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Site 1, `fold.binary`: a §4.2 constant expression, folded before the
    // Model field is written. 2^31 is one step past the top of §3.2's range.
    try std.testing.expect(std.mem.find(u8, src, "big: i64 = -2147483648") != null);
    // §4.2.11 `<<` at the same width: `1 << 31` is the sign bit, not 2^31.
    try std.testing.expect(std.mem.find(u8, src, "sh: i64 = -2147483648") != null);
    // Site 2, `analysis.foldConst`: a §6.3.4 default over another parameter,
    // folded for the field initializer and re-emitted in `derive` for the
    // overridden case. -2^31 + 1, so the two folds have to agree on -2^31 first.
    try std.testing.expect(std.mem.find(u8, src, "chained: i64 = -2147483647") != null);
    try std.testing.expect(std.mem.find(u8, src, "model.chained = @as(i32, @truncate(") != null);
    // Site 3, `codegen.intBin32`: the device. `+%` is the 64-bit wrap that keeps
    // the add from panicking; the truncation is §3.2's width. The left operand
    // is a PARAMETER, so neither fold can reach it and the wrap has to survive
    // as emitted code, which is the site this half of the test is about.
    try std.testing.expect(std.mem.find(u8, src, "@as(i32, @truncate(((@as(i64, model.big)) +% (@as(i64, 1)))))") != null);
}

test "codegen: a unit whose target is defined in one arm returns a VALUE, not undefined" {
    var h: Harness = undefined;
    // §4.5 the operator's input unit is sliced from the argument, which here is
    // only defined on the taken arm. Returning `undefined` from the other one is
    // undefined behavior in the device AND silently corrupts the operator's
    // history, because `updateState` pushes whatever comes back.
    // The condition is a §3.4 PARAMETER, which §5.8.1 licenses (a `constant_
    // primary` cannot move mid-analysis, so the operator never misses a step)
    // while `elabConst` still refuses to fold it away (a model card overrides
    // it). So the diamond is real and the operator is legal. A probe condition
    // here would be E0514.
    try Harness.run(std.testing.allocator,
        \\module g(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  parameter real en = 1.0;
        \\  analog begin
        \\    if (en > 0.5)
        \\      I(p, n) <+ transition(V(p, n), 0, 1n, 1n);
        \\    else
        \\      I(p, n) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.find(u8, src, "fn g__common__core(").?;
    // `"\n}\n"`, not `"\n}"`: the core's return type is an anonymous struct
    // written into the signature, and it closes with `\n} {`.
    const end = std.mem.findPos(u8, src, at, "\n}\n").?;
    const body = src[at..end];
    // Hoisted slots of one mask share one `var h0: [n]zOf(...) = undefined`, so
    // the guarantee is two facts: the array is exactly as long as the number of
    // zero-seeds, and every seed writes `S.con(0.0)`. The only hoists are the
    // two returned fields (the one-arm operator input and the contribution
    // phi); every other slot is a `const` at its definition (`probeBody`).
    try std.testing.expect(std.mem.find(u8, body, "    var h0: [2]zOf(S, 0x3) = undefined;") != null);
    var hoists: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    h0[")) continue;
        hoists += 1;
        try std.testing.expect(std.mem.endsWith(u8, line, "= zTo(S, 0x3, S.con(0.0));"));
    }
    try std.testing.expectEqual(@as(usize, 2), hoists);
}

test "codegen: §4.5.8/§4.5.9 an omitted rate argument copies the one that was given" {
    // §4.5.8: "If only a positive rise_time value is specified, the simulator
    // uses it for both rise and fall times." §4.5.9: max_neg_slew_rate "defaults
    // to the opposite of the max_pos_slew_rate."
    //
    // A neutral default (`fall = 0.0`, `max_neg = 1e300`) would make the short
    // spelling of each operator differ from the long one with the same number.
    //
    // Asserted on the emitted call rather than by diffing the two spellings,
    // because `slew(x, 2e8, -2e8)` renders `@abs(-2e8)` and the short form
    // renders `@abs(2e8)`: the same limit, different text.
    const cases = [_]struct { call: []const u8, want: []const u8 }{
        .{
            // §4.5.8 passes rise and fall separately, so the copy is the same
            // number in the last two argument positions.
            //
            // `0.0000000022`, not `0.0000000022000000000000003`: `2.2n` is one
            // `parseFloat` of `2.2e-9`, not `2.2 * 1e-9` (1 ulp apart; see
            // lexer.zig's "§2.6.2 a scale factor rounds ONCE" test).
            .call = "transition(V(p, n), 0, 2.2n)",
            .want = "0.0000000022, 0.0000000022)",
        },
        .{
            .call = "slew(V(p, n), 2e8)",
            .want = "sim.dt, 200000000.0, @abs(200000000.0))",
        },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ {s};
            \\endmodule
        , .{c.call});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);

        std.testing.expect(std.mem.find(u8, out, c.want) != null) catch |e| {
            std.debug.print("{s}: expected to emit `{s}`\n", .{ c.call, c.want });
            return e;
        };
    }
}

test "codegen: §5.9.1 a short-circuit loop condition still reaches the loop's branch" {
    // §4.2.7 `&&` splits its expression across blocks, so after lowering a
    // `while` condition the current block is the short-circuit join, not the
    // loop header. A loop branch placed in the header strands the rhs and join
    // blocks: their slots are declared but never assigned, and the loop
    // branches on an `undefined` local.
    //
    // Asserted structurally, not on one temporary's name: every declared slot
    // must be written somewhere in the body.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin : body
        \\    real x, y; integer i;
        \\    x = 1e6; y = V(p, n); i = 0;
        \\    while ((i <= 4) && (abs(y - x) > 1e-12)) begin
        \\      x = y;
        \\      y = 2.0 * y + 1.0;
        \\      i = i + 1;
        \\    end
        \\    I(p, n) <+ y;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The rhs of the `&&` is emitted.
    try std.testing.expect(std.mem.find(u8, src, "zAbs(S, ") != null);

    // The model's own slots, past the file-scope helpers.
    var it = std.mem.splitScalar(u8, src[std.mem.find(u8, src, "// ---- the model, in one declaration ----").?..], '\n');
    while (it.next()) |line| {
        const decl = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, decl, "var t")) continue;
        const name = decl[4 .. std.mem.findScalar(u8, decl, ':') orelse continue];
        var buf: [32]u8 = undefined;
        const store = try std.mem.print(&buf, "{s} = ", .{name});
        std.testing.expect(std.mem.find(u8, src, store) != null) catch |e| {
            std.debug.print("slot `{s}` is declared but never assigned\n", .{name});
            return e;
        };
    }
}

test "codegen: §4.5.7 a delay computed from parameters renders as an expression over `model`" {
    // `td = len * sqrt(l * c)` is how every transmission line in the wild
    // spells its delay (devices/models/lossy_tline.va:135,
    // coupled_tlines.va:110). It is neither a literal nor a bare parameter, so
    // `f64Expr` must render it as an expression, never an `@compileError`
    // pasted into one.
    //
    // §4.5.7 permits it: `absdelay(input, td [, maxdelay])` takes td as an
    // analog_expression, and with no maxdelay "the value of td when the
    // absdelay() is first evaluated shall be used", which for an expression
    // over parameters is its value at every evaluation.
    //
    // Also pins the ASSIGNMENT: `td` is a `real` variable, not a parameter, so
    // this only works because the walk runs on SSA values rather than on names.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tl(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real len = 1.0 from (0:inf);
        \\  parameter real l = 250e-9 from (0:inf);
        \\  parameter real c = 100e-12 from (0:inf);
        \\  real td;
        \\  analog begin
        \\    td = len * sqrt(l * c);
        \\    I(p, n) <+ absdelay(V(p, n), td);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.find(
        u8,
        src,
        "sim.dt, (model.len) * (@sqrt((model.l) * (model.c))))",
    ) != null);
    try std.testing.expect(std.mem.find(u8, src, "@compileError") == null);
}

test "codegen: §5.6.5 a zero-short switch branch emits a collapse hook" {
    // diode.va's access-resistance idiom: rs > 0 selects a real resistor,
    // rs == 0 a retained 0 V short that ngspice would collapse at setup
    // (DIOsetup: posPrimeNode = posNode).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "pub fn collapse(comptime S: type, model: *const Model, inst: *const Instance) [n_u]?u8",
    ) != null);
    // The internal node AND the branch-flow unknown both alias onto the port,
    // so the pair's stamps land on one slot and cancel.
    //
    // Asserted through the union-find emission, which handles chained shorts
    // (BSIM4 rgateMod=0 retains V(g,gm) and V(gm,gi), sharing gm; see
    // `collapse`'s doc comment). `ai` is resolved by the `if (r != u)` loop
    // over every unknown, so it is not written by name; the branch-flow row
    // is, because it is not a union member.
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "zCollapseUnion(&parent, @intFromEnum(U.ai), @intFromEnum(U.a));",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "out[@intFromEnum(U.flowZ28aZ2caiZ29)] = zCollapseRoot(&parent, @intFromEnum(U.a));",
    ) != null);
    // Min-index root, so `a` (a port at index 0) is the target and never a
    // mover. That ordering is what lets the host resolve aliases ascending.
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "if (ra < rb) parent[rb] = ra else parent[ra] = rb;",
    ) != null);
}

test "codegen: table capture is isolated from topology queries" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c; electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  real xs[0:1], ys[0:1];
        \\  analog begin
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else V(rsb) <+ 0.0;
        \\    xs[0]=0; xs[1]=1; ys[0]=$abstime; ys[1]=$abstime+2;
        \\    I(ai, c) <+ $table_model(0.5,xs,ys);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const collapse = src[std.mem.find(u8, src, "pub fn collapse(") orelse return error.NoCollapse ..];
    try std.testing.expect(std.mem.find(u8, collapse, "var pin = inst.*;") != null);
    try std.testing.expect(std.mem.find(u8, collapse, "core(S, xr, model, &pin, .{})") != null);
}

test "codegen: no collapse hook without the zero-short pattern" {
    // An unconditional resistor has nothing to collapse.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn collapse") == null);
}

test "codegen: a zero short still collapses after if-conversion makes its join a select" {
    // The diode idiom again, through ifconv as root.zig runs it. Both arms
    // are pure, so the diamond converts and the retention flag and the
    // potential accumulator become `select`s: `select(rs > 0, 0, 1)` and
    // `select(rs > 0, 0, 0)`. `zeroOnEveryPath` must see through them, or
    // whether a model collapses would hang on whether ifconv converted it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expect(try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null) >= 1);
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn collapse(") != null);
    try std.testing.expect(std.mem.find(
        u8,
        src,
        "zCollapseUnion(&parent, @intFromEnum(U.ai), @intFromEnum(U.a));",
    ) != null);
}

test "codegen: an OBSERVED zero short is not collapsed" {
    // §5.4.2 `I(rsb)` reads the branch-flow unknown, which `collapse` would
    // alias onto a node voltage: the model would read V(a), not its current.
    // Here the arm holds `sqrt`, so ifconv keeps the phi form.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  real seen;
        \\  analog begin
        \\    seen = I(rsb);
        \\    I(ai, c) <+ 1e-3 * V(ai, c) + 0.0 * seen;
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs + 0.0 * sqrt(rs);
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn collapse") == null);
}

test "codegen: an x-steered zero short is NOT collapsed" {
    // The guard reads a probe, so which arm is retained changes per
    // evaluation; a build-time alias would be a lie. `buildFree` refuses it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (V(a, c) > 1.0) I(a, ai) <+ 1e3 * V(a, ai);
        \\    else               V(a, ai) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn collapse") == null);
}

test "codegen: §4.5 a control argument that is a solve result is E0515, not generated Zig" {
    // The other half: a control argument the CLAUSE makes constant and that
    // genuinely cannot be resolved must be a diagnostic at the `.va` line. An
    // `@compileError` pasted into an expression is not one: it reads as an
    // engine bug in generated code.
    //
    // §4.5.8's rise_time, not §4.5.7's td: Table 4-20 lists every one of
    // `transition`'s times among the CONSTANT expression arguments and
    // `absdelay`'s td among the DYNAMIC ones, so `absdelay(V(p,n), V(c))` is
    // legal and compiled (see `isDynCtrlArg` and
    // ch04_expressions/absdelay_td_frozen_without_maxdelay.va).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  analog I(p, n) <+ transition(V(p, n), 0, V(c));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (0..h.bag.count()) |i| {
        const e = h.bag.at(i);
        if (e.code != .E0515) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        // A node probe has no instruction of its own to point at, which is what
        // `ctrl_tok`'s fallback to the operator call exists for.
        try std.testing.expect(e.span.end > e.span.start);
    }
    try std.testing.expect(found);
    // Refused as a whole unit: an `@compileError` statement that replaces the
    // body, never one pasted into the middle of an expression.
    try std.testing.expect(std.mem.find(u8, src, "\n    @compileError(\"LRM 4.5") != null);
    try std.testing.expect(std.mem.find(u8, src, "(@compileError") == null);
}

test "codegen: metadata control failure stays fatal with and without diagnostics" {
    // §4.5.14 permits first-use capture of a nonliteral constant argument.
    // A dynamic transition rise_time is unsupported, not invalid source.
    // Whatever its diagnostic, callers must never receive a success flag
    // because a later unit reset the per-body `fatal` field.
    for ([_]bool{ false, true }) |with_diags| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator,
            \\module sampled(p, n, c);
            \\  inout p, n, c;
            \\  electrical p, n, c;
            \\  analog I(p,n) <+ transition(V(p,n), 0, V(c));
            \\endmodule
        , &h);
        defer h.deinit();
        const v = try proof.prove(std.testing.allocator, &h.mir, &h.lowered, .{}, &h.bag);
        defer v.deinit(std.testing.allocator);
        try std.testing.expect(!h.bag.failed());
        const a = h.arena_state.allocator();
        const d = try generate(a, a, &h.mir, &h.lowered, v, .{
            .diags = if (with_diags) &h.bag else null,
        });
        try std.testing.expect(d.compile_error);
        try std.testing.expectEqual(with_diags, h.bag.failed());
    }
}

test "codegen: §12.32.3 an unregistered system function is W0852 and a host call, not a refusal" {
    // The other side of the test above, and the distinction the whole W0852
    // ruling rests on: an unregistered `$name` has no value the LRM fixes, so
    // the unit must still compile, but not silently. §12.32.3's own sampnhold
    // listing, which is what puts one of these in a contribution.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sampnhold(out, in);
        \\  inout out, in;
        \\  electrical out, in;
        \\  parameter real period = 1e-3;
        \\  analog V(out) <+ $sampler(V(in), period);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (0..h.bag.count()) |i| {
        const e = h.bag.at(i);
        if (e.code != .W0852) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        try std.testing.expect(e.span.end > e.span.start); // the call, not the file
    }
    try std.testing.expect(found);
    // Compiles: a refusal here would reject legal source (§2.8.3).
    try std.testing.expect(std.mem.find(u8, src, "@compileError") == null);

    // §2.8.3/§12.32: the name is exported for a host to bind, not answered
    // here with a substitute value.
    try std.testing.expect(std.mem.find(u8, src, "pub const systf_calls") != null);
    try std.testing.expect(std.mem.find(u8, src, ".{ .name = \"$sampler\", .tok = ") != null);
    try std.testing.expect(std.mem.find(u8, src, "inst.systf.?") != null);
}

test "codegen: Instance carries a `systf` slot only when a `$name` is left to the host" {
    // The slot is 8 bytes on every instance, so a device that resolves
    // every `$name` itself has none (`Lowered.Uses.systf`).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module r(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real g = 1.0;
        \\  analog I(p, n) <+ g * V(p, n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "systf:") == null);
    try std.testing.expect(std.mem.find(u8, src, "pub const systf_calls") == null);
}

test "codegen: §3.4.2 an integer parameter takes the narrowest field its range and default allow" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module nw(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer m = 1 from [0:3];
        \\  parameter integer t = 1 from [-1:1] exclude 0;
        \\  parameter integer k = 7;
        \\  parameter integer d = m + 1 from [0:3];
        \\  parameter integer w = 300 from [0:1000];
        \\  parameter real g = 1.0;
        \\  analog I(p, n) <+ g * V(p, n) * (m + t + k + d + w);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The range and the default size the field; no range, or a `derive`
    // target, keeps the i64 carrier of §3.4.1's 32-bit value.
    try std.testing.expect(std.mem.find(u8, src, "    m: u8 = 1,\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "    t: i8 = 1,\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "    k: i64 = 7,\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "    d: i64 = 2,\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "    w: u16 = 300,\n") != null);
    // A read widens to the i64 the bodies compute in.
    try std.testing.expect(std.mem.find(u8, src, "@as(i64, model.m)") != null);
}

test "codegen: §9.19 the given flags are one bitset, named by given_params and set by setGiven" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module gv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real a = 1.0;
        \\  parameter real b = a;
        \\  parameter real c = 2.0;
        \\  analog I(p, n) <+ V(p, n) * (b + c + $param_given(c));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // `b` is a derive target, `c` is asked about, `a` is neither.
    try std.testing.expect(std.mem.find(u8, src, "    given__: std.StaticBitSet(2) = .empty,\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "    pub const given_params = [_][]const u8{\n        \"b\",\n        \"c\",\n    };") != null);
    try std.testing.expect(std.mem.find(u8, src, "    pub fn setGiven(model: *Model, name: []const u8) void {") != null);
    try std.testing.expect(std.mem.find(u8, src, "if (!model.given__.isSet(0)) model.b = model.a;") != null);
    try std.testing.expect(std.mem.find(u8, src, "@intFromBool(model.given__.isSet(1))") != null);
    try std.testing.expect(std.mem.find(u8, src, "__given") == null);
}

test "codegen: a card value eval reads is copied into Setup beside the derived values" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cp(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 2.0;
        \\  parameter real s = 3.0;
        \\  analog I(p, n) <+ V(p, n) * exp(r) + V(p, n) * V(p, n) * s;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // `exp(r)` is derived; `s` is a plain read, copied so the core touches
    // `su` alone. `r` feeds only the derived root, so it is not copied.
    try std.testing.expect(std.mem.find(u8, src, "    r: [2]f64 = @splat(") != null);
    try std.testing.expect(std.mem.find(u8, src, "model.su.r[0] = (S.con(model.s)).val();") != null);
    try std.testing.expect(std.mem.find(u8, src, ".scale(model.su.r[0])") != null);
    // The card is read once, by the copy.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "S.con(model.s)"));
    // With nothing derived there is no `Setup` to pack into: the card is read.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cq(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real s = 3.0;
        \\  analog I(p, n) <+ V(p, n) * s;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const src2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src2, "pub const Setup") == null);
    try std.testing.expect(std.mem.find(u8, src2, "(model.s)") != null);
}

test "codegen: a systf call reassembles the host's value and partials into one S" {
    // The shape §12.22.1 forces, and the reason it is forced: `eval` is generic
    // over S and a function POINTER cannot be, so the host returns a value and
    // writes partials and the call site rebuilds the dual. Each graft term is
    // `arg.addC(-arg.val()).scale(p)` (VALUE zero, DERIVATIVE p·d(arg)), so on
    // the plain-f64 instantiation the residual reads the host's value exactly
    // and on the dual one it also carries the host's slope.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module twice(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ $foo(V(p,n)) + $foo(V(p,n)) + $bar(V(p,n));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One entry per CALL, not per name: §12.32.1 runs calltf for each
    // invocation with `vpi_handle(vpiSysTfCall, NULL)` naming that call, so the
    // host must be told which call is running. The two `$foo` calls are two
    // entries (the application binds them by their shared name), `$bar` a third.
    const tbl = src[std.mem.find(u8, src, "pub const systf_calls").?..];
    const rows = tbl[0..std.mem.find(u8, tbl, "};").?];
    try std.testing.expect(std.mem.count(u8, rows, ".{ .name = \"$foo\", .tok = ") == 2);
    try std.testing.expect(std.mem.count(u8, rows, ".{ .name = \"$bar\", .tok = ") == 1);
    try std.testing.expect(std.mem.count(u8, rows, ".name =") == 3);
    // …and each call site passes its own index.
    var buf: [32]u8 = undefined;
    for (0..3) |k| try std.testing.expect(std.mem.count(u8, src, try std.mem.print(&buf, "zsh.call(zsh.ctx, {d},", .{k})) == 1);

    // The graft, spelled out. `.val()` feeds the host, `.addC(-...).scale(...)`
    // brings the partial back; dropping either half is the failure this pins.
    try std.testing.expect(std.mem.find(u8, src, ".val() }") != null);
    try std.testing.expect(std.mem.find(u8, src, ".addC(-zsv[0]).scale(zsp[0])") != null);
}

test "codegen: systf_calls marks a task call and leaves a function call unmarked" {
    // §2.8.3: `$put(c, V(p, n));` is a statement, so a task, whose output
    // argument c is read back (§12.22.2); `$get(V(p, n))` sits in an
    // expression, so a function. `contract.Systf.task` tells a host which,
    // and `contract.validate` refuses outputs on a function.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module both(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  real c;
        \\  analog begin
        \\    $put(c, V(p,n));
        \\    I(p,n) <+ c + $get(V(p,n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const tbl = src[std.mem.find(u8, src, "pub const systf_calls").?..];
    const rows = tbl[0..std.mem.find(u8, tbl, "};").?];
    const put = rows[std.mem.find(u8, rows, "\"$put\"").?..];
    try std.testing.expect(std.mem.startsWith(u8, put[std.mem.find(u8, put, ".outs").?..], ".outs = 0x1, .task = true }"));
    const get = rows[std.mem.find(u8, rows, "\"$get\"").?..];
    try std.testing.expect(std.mem.find(u8, get[0..std.mem.find(u8, get, "}").?], ".task") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, ".task = true"));
}

test "codegen: host parameter derivation reconstructs unconverted pure conditional phis" {
    // Harness intentionally skips if-conversion. The public driver also tests
    // the converted selects through the 90_dependent_control execution fixtures.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module conditional_parameter(p);
        \\  inout p; electrical p;
        \\  parameter real a = 0.0;
        \\  parameter real b = 0.3;
        \\  localparam integer decision = (a > 0.0) && (a < b);
        \\  localparam real value = decision ? (b > 0.0 ? b : 2.0) : 3.0;
        \\  analog I(p) <+ value * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "model.decision = ") != null);
    try std.testing.expect(std.mem.find(u8, src, "model.value = @as(f64, if (") != null);
    try std.testing.expect(std.mem.find(u8, src, "(model.a) < (model.b)") != null);
}

test "codegen: an unsupported dependent default diagnoses instead of freezing" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module unsupported_parameter;
        \\  parameter integer amount = 2;
        \\  localparam integer size = $realtobits(1.0 * amount);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.UnsupportedParameterDefault, h.gen(std.testing.allocator));
    for (0..h.bag.count()) |i| if (h.bag.at(i).code == .E1004) return;
    return error.MissingDiagnostic;
}

test "codegen: §3.4 a default with no compile-time value is W1050, a derived one is silent" {
    // The guard on the `0` field initializer, and the line it must NOT cross.
    // `hot` reads §9.15's `dt`, the host's step, which changes during a run:
    // nothing folds it and nothing derives it, so `Model{}.hot` ships as 0 and
    // the host has to write the field. `warm` is 2*`base`, which §6.3.4 makes
    // a `derive()` line; the same `0` initializer is honest there because
    // `derive` overwrites it, so warning about it would be noise on every
    // dependent parameter in the suite. `shr` reads `shrink`, which VerA
    // knows (1, VD-072), so §9.15 returns 1 and never the fallback (#51).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module pd(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real base = 3.0;
        \\  parameter real warm = 2.0 * base;
        \\  parameter real hot  = $simparam("dt");
        \\  parameter real shr = $simparam("shrink", 1e-12);
        \\  analog I(p, n) <+ V(p, n) * (warm + hot + shr);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var hits: usize = 0;
    for (0..h.bag.count()) |i| {
        const e = h.bag.at(i);
        if (e.code != .W1050) continue;
        hits += 1;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        try std.testing.expect(e.span.end > e.span.start); // the declaration
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
    // A warning, never a refusal: the device still compiles, because §9.18 says
    // nothing that makes this source illegal.
    try std.testing.expect(std.mem.find(u8, src, "@compileError") == null);
    try std.testing.expect(std.mem.find(u8, src, "shr: f64 = 1.0,") != null);
    // And `warm` is the derived half of the claim: initializer 0.0, `derive`
    // writing the §6.3.4 value over it.
    try std.testing.expect(std.mem.find(u8, src, "model.warm = (2.0) * (model.base);") != null);
}

test "codegen: §3.4 a shape parameter is compiled in and a card that moves it is refused" {
    const src =
        \\module sh(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer N = 3;
        \\  parameter real g = 1.0;
        \\  real b[0:N];
        \\  analog begin
        \\    b[0] = g;
        \\    I(p, n) <+ b[0] * V(p, n);
        \\  end
        \\endmodule
    ;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, src, &h);
    defer h.deinit();
    const text = try h.gen(std.testing.allocator);
    // The bound read `N`, so `N` is checked; `g` shapes nothing and is not.
    try std.testing.expect(std.mem.find(u8, text, "    if (@as(i32, @truncate(model.N)) != 3) return \"N\";\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "model.g !=") == null);

    // `--param N=5`: the field initializer AND the check are the compiled value.
    var o: Harness = undefined;
    try Harness.runOver(std.testing.allocator, src, &.{.{ .name = "N", .value = 5 }}, &o);
    defer o.deinit();
    const over = try o.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, over, "N: i64 = 5,") != null);
    try std.testing.expect(std.mem.find(u8, over, "    if (@as(i32, @truncate(model.N)) != 5) return \"N\";\n") != null);
}

test "codegen: §6.6 a parameter in a generate scheme fixes structure, so it is a shape parameter" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module gs(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer sel = 1;
        \\  generate
        \\    if (sel) begin : on
        \\      analog I(p, n) <+ V(p, n);
        \\    end
        \\  endgenerate
        \\endmodule
    , &h);
    defer h.deinit();
    const text = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, text, "    if (@as(i32, @truncate(model.sel)) != 1) return \"sel\";\n") != null);
}

test "codegen: §3.4.7 a card write through an alias sets the original and its __given (#76)" {
    // §3.4.7: after `.trise(5)` "the value of the parameter dtemp, as used in
    // the module equations ..., is 5", so the original was overridden: §9.19
    // `$param_given(dtemp)` is 1, and §6.3.4's default (`dtemp = a`) must not
    // erase it. `c` has no `__given` (its default folds, nothing asks), so
    // its alias copies the value alone.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module al(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real a = 1.0;
        \\  parameter real dtemp = a;
        \\  parameter real c = 2.0;
        \\  aliasparam trise = dtemp;
        \\  aliasparam cc = c;
        \\  analog I(p, n) <+ V(p, n) * (dtemp + c + $param_given(dtemp));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Bits: `dtemp` 0 (the only flagged parameter), then the aliases
    // `trise` 1 and `cc` 2 (`given_params`).
    try std.testing.expect(std.mem.find(u8, src, "    given__: std.StaticBitSet(3) = .empty,\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "    pub const given_params = [_][]const u8{\n        \"dtemp\",\n        \"trise\",\n        \"cc\",\n    };") != null);
    const alias_then_default =
        \\    if (model.given__.isSet(1)) {
        \\        model.dtemp = model.trise;
        \\        model.given__.set(0);
        \\    }
        \\
    ;
    const at = std.mem.find(u8, src, alias_then_default) orelse return error.TestUnexpectedResult;
    // The alias is folded first, so the guarded default sees the raised flag.
    const guard = std.mem.find(u8, src, "if (!model.given__.isSet(0)) model.dtemp = model.a;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(at < guard);
    try std.testing.expect(std.mem.find(u8, src, "    if (model.given__.isSet(2)) model.c = model.cc;\n") != null);
    // Only `dtemp`'s bit is raised in `derive`: `c` has none to raise.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "\n        model.given__.set("));
}

test "codegen: §3.4.2 checkRange names a card value outside its from/exclude ranges (#80)" {
    // §3.4.2: "It shall be an error only if the value of the parameter is out
    // of range during simulation." Several `from` ranges are a union and an
    // `exclude` removes from it, so `r` is refused outside (0:inf) or at 2,
    // and `k` outside [1:5] ∪ [10:12]. `s`'s bound reads `lo`, which the card
    // can move, so it has no literal value and `s` is not checked (VD-125).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module rg(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1 from (0:inf) exclude 2;
        \\  parameter integer k = 3 from [1:5] from [10:12];
        \\  parameter real lo = 0;
        \\  parameter real s = 1 from [lo:10];
        \\  analog I(p, n) <+ V(p, n) * (k + s + lo) / r;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub fn checkRange(model: *const Model) ?[]const u8 {\n") != null);
    try std.testing.expect(std.mem.find(u8, src,
        \\        const v: f64 = model.r;
        \\        if (!((v > 0.0 and v < @as(f64, @bitCast(@as(u64, 0x7ff0000000000000))))) or (v >= 2.0 and v <= 2.0)) return "r";
        \\
    ) != null);
    try std.testing.expect(std.mem.find(u8, src,
        \\        const v: f64 = @floatFromInt(model.k);
        \\        if (!((v >= 1.0 and v <= 5.0) or (v >= 10.0 and v <= 12.0))) return "k";
        \\
    ) != null);
    try std.testing.expect(std.mem.find(u8, src, "return \"s\";") == null);
    try std.testing.expect(std.mem.find(u8, src, "return \"lo\";") == null);
}

test "codegen: §3.4.2 a device with no checkable range has no checkRange" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module nr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1;
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "checkRange") == null);
}

test "codegen: §9.15 $simparam(\"tnom\") is the HOST's nominal temperature" {
    // `tnom` must not fold to the constant 27: a SPICE deck setting `.options
    // tnom` would be ignored, and a compact model derives its whole parameter
    // set from the nominal temperature.
    //
    // ngspice's shape, per model setup (b4set.c:1950): `if (!tnomGiven) tnom =
    // CKTnomTemp`. Here that is the `__given` guard `emitDerive` already writes
    // for every derived parameter, over a Model field the host writes once.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tn(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real tnom  = $simparam("tnom");
        \\  parameter real tnomk = $simparam("tnom") + 273.15;
        \\  analog I(p, n) <+ V(p, n) * (tnom + tnomk);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // ONE host-written field, on Model: `.options tnom` is one number per RUN,
    // so an Instance copy would replicate a global per instance, and two reads
    // of the same simparam must not become two fields.
    try std.testing.expect(std.mem.count(u8, src, "nom_temp__: f64 = 27.0,") == 1);

    // Table 9-27's declared default is the field initializer, in Celsius, so
    // `Model{}` (a host that writes nothing) reads 27. `tnomk` pins that
    // `27.0 + 273.15` folds to the literal `300.15` exactly.
    try std.testing.expect(std.mem.find(u8, src, "tnom: f64 = 27.0,") != null);
    try std.testing.expect(std.mem.find(u8, src, "tnomk: f64 = 300.15,") != null);

    // Precedence: the card wins. `__given` is the same flag §9.19 uses, raised
    // by the host's `applyKv` when the model card named the parameter.
    try std.testing.expect(std.mem.find(u8, src, "if (!model.given__.isSet(0)) model.tnom = model.nom_temp__;") != null);
    try std.testing.expect(std.mem.find(u8, src, "if (!model.given__.isSet(1)) model.tnomk = (model.nom_temp__) + (273.15);") != null);

    // A default that reads the host's table is not W1050: `derive()`
    // overwrites the field, which is that warning's own silence condition.
    for (0..h.bag.count()) |i| try std.testing.expect(h.bag.at(i).code != .W1050);
}

test "codegen: §9.15 $simparam(\"tnom\") read from the body is the same field" {
    // Not only the §3.4 default position: a model that asks mid-body gets the
    // host's value too, or the two spellings of one question would disagree.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tb(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * $simparam("tnom");
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "nom_temp__: f64 = 27.0,") != null);
    try std.testing.expect(std.mem.find(u8, src, "S.con(model.nom_temp__)") != null);
}

test "codegen: §9.15 $simparam reltol/abstol/vntol are host fields, one per name read" {
    // The `tnom` shape for SPICE's Newton tolerances: a Model field the host
    // writes, initialized to SPICE's default. A name the model never reads
    // costs its Model nothing, so `abstol` here has no field.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tol(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rt = $simparam("reltol");
        \\  analog I(p, n) <+ V(p, n) * (rt + $simparam("vntol", 0.5));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.count(u8, src, "reltol__: f64 = 0.001,") == 1);
    try std.testing.expect(std.mem.count(u8, src, "vntol__: f64 = 0.000001,") == 1);
    try std.testing.expect(std.mem.find(u8, src, "abstol__") == null);
    try std.testing.expect(std.mem.find(u8, src, "if (!model.given__.isSet(0)) model.rt = model.reltol__;") != null);
    // A known name ignores its fallback (§9.15).
    try std.testing.expect(std.mem.find(u8, src, "S.con(model.vntol__)") != null);
}

test "codegen: §9.17.1 $discontinuity(-1) is `limit`'s verdict, with no state or iteration hook" {
    // The request is a function of the iterate alone, so it keeps no
    // accepted-step state: the device is `eval` + `limit`, which a host can
    // run where it runs `eval`. The verdict is read at `old`, the point the
    // host last evaluated.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module rj(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    if (abs(V(p, n)) > 0.7) $discontinuity(-1);
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    for ([_][]const u8{ "pub fn checkConvergence(", "pub fn advanceIteration(", "pub const State ", "pub fn updateState(" }) |d|
        try std.testing.expect(std.mem.find(u8, src, d) == null);
    try std.testing.expect(std.mem.find(u8, src, "zVals(S, &old)") != null);
    try std.testing.expect(std.mem.find(u8, src, ".converged = m.f0 == 0 };") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub const limit_writes: u64 = 0x0;") != null);
}

test "codegen: §9.13 the emitted draws are IEEE 1364 §17.9.3's, digit for digit" {
    // Same arrangement as the scanner below: the kernels are `@embedFile`d into
    // every device, so what is checked here is byte-for-byte what runs there.
    //
    // §9.13.3 binds this family to IEEE 1364 §17.9.3's C listing (Table 9-26),
    // so there ARE digits to pin. Every literal below was produced by COMPILING
    // AND RUNNING that listing (the copy in Icarus Verilog's vpi/sys_random.c,
    // cross-checked against Verilator's verilated_probdist.cpp; provenance and
    // URLs in rng_kernels.zig's header) with `zig cc`, never hand-computed.
    // The log/sqrt-free rows (`uniform`, `rtl_dist_uniform`, the LCG steps) are
    // compared EXACTLY: they are pure IEEE-754 mul/add/div and the port must
    // reproduce the C bit for bit. The transcendental rows allow libm-vs-@log
    // ulp drift and nothing more; their SEEDS are still exact, because the
    // seed path is integer arithmetic and admits no drift at all.
    const k = @import("kernels").rng_kernels;
    const eps = std.testing.expectApproxEqRel;
    // $random from seed 7 = rtl_dist_uniform(&s, INT_MIN, INT_MAX), twice; the
    // second pair proves the write-back rejoined the reference stream.
    try std.testing.expectEqual(@as(f64, -2146999808), k.zRngRand(7));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngRandNext(7));
    try std.testing.expectEqual(@as(f64, 1181502348), k.zRngRand(483484));
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngRandNext(483484));
    try std.testing.expectEqual(@as(f64, -2144582656), k.zRngRand(42));
    // One plain `uniform()` step, the Instance latch's advance.
    try std.testing.expectEqual(@as(f64, 483484), k.zRngNext(7));
    try std.testing.expectEqual(@as(f64, -483482), k.zRngNext(-7));
    try std.testing.expectEqual(@as(f64, -1844104698), k.zRngNext(0)); // 259341593 escape
    try std.testing.expectEqual(@as(f64, 69070), k.zRngNext(1));
    try std.testing.expectEqual(@as(f64, 2147345511), k.zRngNext(2147483646));
    // Table 9-26 `$rdist_uniform` → `uniform`: exact, mul/add only.
    try std.testing.expectEqual(@as(f64, 0.0011265279204053513), k.zRngUniform(7, 0.0, 10.0));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngUniformNext(7, 0.0, 10.0));
    try std.testing.expectEqual(@as(f64, 7.7508995236036071), k.zRngUniform(483484, 0.0, 10.0));
    // `$dist_uniform` → `rtl_dist_uniform`: an integer on the CLOSED range.
    try std.testing.expectEqual(@as(f64, 0), k.zRngIUniform(7, 0, 10));
    try std.testing.expectEqual(@as(f64, 1), k.zRngIUniform(7, 1, 6));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngIUniformNext(7, 0, 10));
    // The transcendental rows, each with its exact reference seed.
    try eps(@as(f64, 1.151634785351684), k.zRngNormal(7, 0.0, 1.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -1368524349), k.zRngNormalNext(7, 0.0, 1.0));
    try eps(@as(f64, 27.273600318905594), k.zRngExponential(7, 3.0), 1e-12);
    try std.testing.expectEqual(@as(f64, 483484), k.zRngExponentialNext(7, 3.0));
    try std.testing.expectEqual(@as(f64, 0), k.zRngPoisson(7, 3.0));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngPoissonNext(7, 3.0));
    try eps(@as(f64, 18.691952590208434), k.zRngChiSquare(7, 4.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngChiSquareNext(7, 4.0));
    try eps(@as(f64, 0.53274261066788675), k.zRngT(7, 4.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -1368524349), k.zRngTNext(7, 4.0));
    try eps(@as(f64, 14.018964442656326), k.zRngErlang(7, 2.0, 3.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngErlangNext(7, 2.0, 3.0));
    // §9.13.1's width sentence: "a 32-bit signed integer; it can be positive or
    // negative": both signs occur along the reference stream, and every draw
    // stays inside the width.
    var neg = false;
    var pos = false;
    var sd: i64 = 1;
    for (0..64) |_| {
        const r = k.zRngRand(sd);
        try std.testing.expect(r >= -2147483648.0 and r <= 2147483647.0);
        try std.testing.expectEqual(r, @round(r));
        if (r < 0) neg = true else pos = true;
        sd = @intFromFloat(k.zRngRandNext(sd));
    }
    try std.testing.expect(neg and pos);
    // Repeatability (§9.13.2 "shall always return the same value given the same
    // seed") and finiteness for these particular seeds and ordinary parameters.
    // The family is not finite in general; the proof pass must stay conservative.
    for ([_]i64{ -2147483647, -7, 0, 1, 7, 42, 2147483646 }) |s| {
        try std.testing.expectEqual(k.zRngNext(s), k.zRngNext(s));
        try std.testing.expect(k.zRngNext(s) != @as(f64, @floatFromInt(s))); // inout: different
        try std.testing.expect(std.math.isFinite(k.zRngT(s, 4.0)));
        try std.testing.expect(std.math.isFinite(k.zRngNormal(s, 0.0, 1.0)));
        try std.testing.expect(std.math.isFinite(k.zRngChiSquare(s, 4.0)));
        try std.testing.expect(k.zRngPoisson(s, 3.0) >= 0.0);
    }
}

test "codegen: §9.5.4.2 the emitted scanner is the one the fixtures assert" {
    // The kernels are `@embedFile`d into every device, so the rows checked here
    // are byte-for-byte the code that runs there: the same arrangement
    // `filter_kernels.zig` has, and the reason both live in real Zig files.
    //
    // Every row below is a sentence of §9.5.4.2, and the numbers are the ones
    // tests/conformance/tests/verilog-a/ch09_system_tasks/{048,162,09,06} hold VerA to.
    const k = @import("kernels").str_scan;
    const store = @import("kernels").str_store;
    // "the number of successfully matched and assigned input items is returned"
    try std.testing.expectEqual(@as(i64, 1), k.zScanN("42", "%d"));
    try std.testing.expectEqual(@as(i64, 42), k.zScanI("42", "%d", 0));
    // A suppressed field is consumed, takes no argument and is not counted.
    try std.testing.expectEqual(@as(i64, 1), k.zScanN("12 34", "%*d %d"));
    try std.testing.expectEqual(@as(i64, 34), k.zScanI("12 34", "%*d %d", 0));
    // "a decimal digit string that specifies an optional numerical maximum
    // field width": the field ends there, even mid-number.
    try std.testing.expectEqual(@as(i64, 12), k.zScanI("12345", "%2d", 0));
    // "0 in the event of an early matching failure", and EOF (-1) when the
    // input ends before any conversion at all.
    try std.testing.expectEqual(@as(i64, 0), k.zScanN("hello", "%d"));
    try std.testing.expectEqual(@as(i64, -1), k.zScanN("", "%d"));
    // "%s Matches a string" then "%f ... Matches a floating point number".
    try std.testing.expectEqual(@as(i64, 2), k.zScanN("abc 5.5", "%s %f"));
    try std.testing.expectEqualStrings("abc", k.zScanS("abc 5.5", "%s %f", 0));
    try std.testing.expectEqual(@as(f64, 5.5), k.zScanR("abc 5.5", "%s %f", 1));
    // Literal text in the control string must match, and %e reads back what
    // §9.4.3's `%10.4e` wrote (string_formatting.va's round trip).
    const txt = try std.mem.print(store.zSBuf(0), "value={e:>10.4}", .{0.5});
    try std.testing.expectEqual(@as(f64, 0.5), k.zScanR(txt, "value=%e", 0));
    try std.testing.expectEqual(@as(i64, 0), k.zScanN(txt, "other=%e"));
    // Two call sites, two scratch rows: §9.5.3 gives each writer its own string
    // variable, so one must not overwrite the other's bytes.
    const hex = try std.mem.print(store.zSBuf(1), "{x}", .{@as(i64, 4096)});
    try std.testing.expectEqual(@as(i64, 1000), k.zScanI(hex, "%d", 0));
    try std.testing.expectEqualStrings("value= 5.0000e-1", txt);
}

test "codegen: §9.5 the emitted descriptors are the ones the fixtures assert" {
    // Same arrangement as the two above: the kernels are `@embedFile`d into the
    // printing artifact, so what runs here is byte-for-byte what runs there.
    //
    // Every claim below is a sentence of §9.5.1/§9.5.4/§9.5.5/§9.5.7/§9.5.8, and
    // the digits are the ones tests/conformance/tests/verilog-a/ch09_system_tasks/{07,046,049,050,
    // 051,053,054,158,11} hold VerA to.
    const k = @import("kernels").file_kernels;
    var table: @import("kernels").file_table.ZfTable = .{};
    defer k.zFFreeAll(&table);
    const zc: *anyopaque = &table;
    // The kernels resolve a path relative to the process cwd (which is exactly
    // what makes `ch09_047_missing.dat` a claim about a DIRECTORY, and why
    // tests/suite.zig runs each fixture in its own), so the directory is what
    // has to be unique here: worktrees share one symlinked .zig-cache, and a
    // fixed name there is overwritten by a concurrent run.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [96]u8 = undefined;
    var absent_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/vera-file-kernels-test.dat", .{tmp.sub_path});
    const absent = try std.fmt.bufPrint(&absent_buf, ".zig-cache/tmp/{s}/vera-file-kernels-absent.dat", .{tmp.sub_path});

    // §9.5.1 "the most significant bit (bit 31) of a fd is reserved and shall
    // always be set", and "three file descriptors are pre-opened ...
    // 32'h8000_0000, 32'h8000_0001, and 32'h8000_0002", so a fresh channel's
    // small number is greater than 2.
    const w = k.zFOpen(zc, path, "w", false);
    try std.testing.expect(w & 2147483648 != 0);
    try std.testing.expect(w & 2147483647 > 2);
    // §9.5.2's output side at the byte level: four bytes in, four bytes out.
    try std.testing.expectEqual(@as(i64, 4), k.zFPut(zc, w, "abc\n"));
    _ = k.zFClose(zc, w);

    const r = k.zFOpen(zc, path, "r", false);
    try std.testing.expect(r & 2147483648 != 0);
    // §9.5.5 "$ftell ... the offset from the beginning of the file of the current
    // byte" is 0 before any read.
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(zc, r));
    // §9.5.8 "returns zero otherwise": nothing has been read, so no EOF.
    try std.testing.expectEqual(@as(i64, 0), k.zFEof(zc, r));
    // §9.5.4.1 "until a newline character is read AND TRANSFERRED to str ... the
    // number of characters read is returned in code" is 4, not the 3 a C `fgets`
    // minus its delimiter gives.
    try std.testing.expectEqual(@as(i64, 4), k.zFGets(zc, r));
    try std.testing.expectEqualStrings("abc\n", k.zFLine(zc, 4, r));
    try std.testing.expectEqual(@as(i64, 4), k.zFTell(zc, r));
    // The read that runs off the end is the one §9.5.8 promises a nonzero answer
    // for; the first need not have touched EOF.
    try std.testing.expectEqual(@as(i64, 0), k.zFGets(zc, r));
    try std.testing.expect(k.zFEof(zc, r) != 0);
    // §9.5.5 "$fseek ... 2 sets position to EOF plus offset", and the return is a
    // STATUS: "otherwise, code is set to 0".
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(zc, r, 0, 2));
    try std.testing.expectEqual(@as(i64, 4), k.zFTell(zc, r));
    // "$rewind is equivalent to $fseek (fd,0,0)" in status and in effect.
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(zc, r, 0, 0));
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(zc, r));
    // §9.5.7 "if the most recent operation did not result in an error, then the
    // value returned shall be zero, and the string variable str shall be empty".
    try std.testing.expectEqual(@as(i64, 0), k.zFError(zc, r));
    try std.testing.expectEqualStrings("", k.zFErrorStr(0, r));
    _ = k.zFClose(zc, r);

    // §9.5.1 "if a file cannot be opened (either the file does not exist and the
    // type specified is r ...) a zero is returned for the mcd or fd", and
    // "applications can call $ferror to determine the cause of the most recent
    // error".
    const bad = k.zFOpen(zc, absent, "r", false);
    try std.testing.expectEqual(@as(i64, 0), bad);
    try std.testing.expect(k.zFError(zc, bad) != 0);
    try std.testing.expect(k.zFErrorStr(k.zFError(zc, bad), bad).len != 0);

    // §9.5.1's other overload: "the multichannel descriptor mcd is a 32-bit
    // integer in which a SINGLE BIT is set", bit 0 "always refers to the standard
    // output", and bit 31 "shall always be CLEARED".
    const mcd = k.zFOpen(zc, path, "", true);
    try std.testing.expect(mcd & 2147483648 == 0);
    try std.testing.expect(mcd != 0 and mcd & (mcd - 1) == 0);
    try std.testing.expect(mcd != 1);
    _ = k.zFClose(zc, mcd);
    // "The $fopen function shall reuse channels that have been closed."
    try std.testing.expectEqual(mcd, k.zFOpen(zc, path, "", true));
    _ = k.zFClose(zc, mcd);

    // IEEE 1364-2005 §17.2.4.1/§17.2.4.2, the digital context's two reads on
    // this same table (VAMS §9.5.1.2): `$ungetc` puts a character back without
    // touching the file, the next `$fgetc` reads it, and `$rewind` drops it.
    const gw = k.zFOpen(zc, path, "w", false);
    _ = k.zFPut(zc, gw, "a");
    _ = k.zFClose(zc, gw);
    const g = k.zFOpen(zc, path, "r", false);
    try std.testing.expectEqual(@as(i64, 'a'), k.zFGetc(zc, g));
    try std.testing.expectEqual(@as(i64, 0), k.zFUngetc(zc, 'Z', g));
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(zc, g));
    try std.testing.expectEqual(@as(i64, 'Z'), k.zFGetc(zc, g));
    try std.testing.expectEqual(@as(i64, 0), k.zFUngetc(zc, 'Z', g));
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(zc, g, 0, 0));
    try std.testing.expectEqual(@as(i64, 'a'), k.zFGetc(zc, g));
    // §17.2.8: the read that finds no byte is EOF (-1) and sets the indicator.
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(zc, g, 0, 2));
    try std.testing.expectEqual(@as(i64, -1), k.zFGetc(zc, g));
    try std.testing.expect(k.zFEof(zc, g) != 0);
    _ = k.zFClose(zc, g);

    // VD-084: `$fscanf`'s window and `$fgets` read the pushback first, and
    // the file resumes after the byte it covers.
    const hw = k.zFOpen(zc, path, "w", false);
    _ = k.zFPut(zc, hw, "ab\n");
    _ = k.zFClose(zc, hw);
    const h = k.zFOpen(zc, path, "r", false);
    try std.testing.expectEqual(@as(i64, 'a'), k.zFGetc(zc, h));
    try std.testing.expectEqual(@as(i64, 0), k.zFUngetc(zc, 'Z', h));
    try std.testing.expectEqualStrings("Zb\n", k.zFWindow(zc, h));
    try std.testing.expectEqual(@as(i64, 1), k.zFTake(zc, h, 1, 1));
    try std.testing.expectEqualStrings("b\n", k.zFWindow(zc, h));
    try std.testing.expectEqual(@as(i64, 0), k.zFUngetc(zc, 'Y', h));
    try std.testing.expectEqual(@as(i64, 3), k.zFGets(zc, h));
    try std.testing.expectEqualStrings("Yb\n", k.zFLine(zc, 3, h));
    try std.testing.expectEqual(@as(i64, 3), k.zFTell(zc, h));
    _ = k.zFClose(zc, h);
}

test "codegen: §9.21 the emitted table interpolator is the one the fixtures assert" {
    const k = @import("kernels").table_kernels;
    // A one-derivative stand-in for the device's scalar: enough of the interface
    // `zTable` uses (`con`/`val`/`add`/`addC`/`scale`) to see the Jacobian, which
    // is the half of the answer no fixture can read.
    const S = struct {
        v: f64,
        d: f64 = 0.0,
        const T = @This();
        pub fn con(c: f64) T {
            return .{ .v = c };
        }
        pub fn val(a: T) f64 {
            return a.v;
        }
        pub fn add(a: T, b: T) T {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn addC(a: T, c: f64) T {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn scale(a: T, c: f64) T {
            return .{ .v = a.v * c, .d = a.d * c };
        }
    };
    // §9.21.1's printed sample set: f(x,y) = 0.5x + y on three isolines of y,
    // laid out `y x f(x,y)`: 12 rows of 3 columns, outermost-first. The same
    // twelve rows table_model_lrm_sample_set.va and ch09_table_model_2d.tbl
    // carry.
    const rows = [_]f64{
        0.0, 1.0, 0.5, 0.0, 2.0, 1.0, 0.0, 3.0, 1.5,
        0.0, 4.0, 2.0, 0.0, 5.0, 2.5, 0.0, 6.0, 3.0,
        0.5, 1.0, 1.0, 0.5, 3.0, 2.0, 0.5, 5.0, 3.0,
        1.0, 1.0, 1.5, 1.0, 2.0, 2.0, 1.0, 4.0, 3.0,
    };
    // Figure 9-2's own lookup and its own answer: bracket y=0.25 by the 0.0/0.5
    // isolines, interpolate each at x=3.5 (1.75 and 2.25), interpolate those in
    // y. Every intermediate is dyadic, so this is exact.
    const f = k.zTable(S, 12, 3, 2, 2, "1LL1LL", rows, [_]S{ .{ .v = 0.25 }, .{ .v = 3.5, .d = 1.0 } });
    try std.testing.expectEqual(@as(f64, 2.0), f.v);
    // The scheme is piecewise linear and the samples lie on 0.5x + y, so ∂f/∂x
    // is 0.5: the Jacobian entry a probe in the lookup slot owes the solver.
    try std.testing.expectEqual(@as(f64, 0.5), f.d);

    // §9.21.1 "if the user provides the data in random order the system will
    // sort the data into isolines in each dimension". Same table, rows reversed:
    // without the sort the isolines are shredded and the answer is quietly wrong.
    var back: [36]f64 = undefined;
    for (0..12) |r| for (0..3) |c| {
        back[r * 3 + c] = rows[(11 - r) * 3 + c];
    };
    const g = k.zTable(S, 12, 3, 2, 2, "1LL1LL", back, [_]S{ .{ .v = 0.25 }, .{ .v = 3.5 } });
    try std.testing.expectEqual(@as(f64, 2.0), g.v);

    // table_model_array_control.va: one dimension, two samples on f(x) = 2x,
    // "1LL;1": halfway between them.
    const line = [_]f64{ 1.0, 2.0, 3.0, 6.0 };
    const h1 = k.zTable(S, 2, 2, 1, 1, "1LL", line, [_]S{.{ .v = 2.0, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 4.0), h1.v);
    try std.testing.expectEqual(@as(f64, 2.0), h1.d);
    // Table 9-31: linear extrapolation "extends linearly to the requested point
    // from the endpoint using a slope consistent with the selected interpolation
    // method", so f(0) = 0 and f(5) = 10 off both ends…
    try std.testing.expectEqual(@as(f64, 0.0), k.zTable(S, 2, 2, 1, 1, "1LL", line, [_]S{.{ .v = 0.0 }}).v);
    try std.testing.expectEqual(@as(f64, 10.0), k.zTable(S, 2, 2, 1, 1, "1LL", line, [_]S{.{ .v = 5.0 }}).v);
    // …while constant extrapolation "returns the table endpoint value", and the
    // two ends are independent: `"CL"` clamps below 1.0 and still extrapolates
    // above 3.0. A swapped pair would pass every symmetric test there is.
    const cl = k.zTable(S, 2, 2, 1, 1, "1CL", line, [_]S{.{ .v = 0.0, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 2.0), cl.v);
    try std.testing.expectEqual(@as(f64, 0.0), cl.d); // clamped ⇒ flat
    try std.testing.expectEqual(@as(f64, 10.0), k.zTable(S, 2, 2, 1, 1, "1CL", line, [_]S{.{ .v = 5.0 }}).v);
    try std.testing.expectEqual(@as(f64, 6.0), k.zTable(S, 2, 2, 1, 1, "1LC", line, [_]S{.{ .v = 5.0 }}).v);
    try std.testing.expectEqual(@as(f64, 0.0), k.zTable(S, 2, 2, 1, 1, "1LC", line, [_]S{.{ .v = 0.0 }}).v);
    // §9.21.2's dependent selector picks a COLUMN: two dependents over the same
    // isolines, and `;2` reads the second.
    const two = [_]f64{ 1.0, 2.0, 20.0, 3.0, 6.0, 60.0 };
    try std.testing.expectEqual(@as(f64, 4.0), k.zTable(S, 2, 3, 1, 1, "1LL", two, [_]S{.{ .v = 2.0 }}).v);
    try std.testing.expectEqual(@as(f64, 40.0), k.zTable(S, 2, 3, 1, 2, "1LL", two, [_]S{.{ .v = 2.0 }}).v);

    // Discrete lookup preserves the chosen value and has zero derivative.
    const discrete = [_]f64{ 3, 30, -1, 10, -3, -30, 1, 20 };
    for ([_]f64{ -10, -2, -1.25, 0.25, 2, 10 }, [_]f64{ -30, -30, 10, 20, 30, 30 }) |at, expected| {
        const picked = k.zTable(S, 4, 2, 1, 1, "DLL", discrete, [_]S{.{ .v = at, .d = 1 }});
        try std.testing.expectEqual(expected, picked.v);
        try std.testing.expectEqual(@as(f64, 0), picked.d);
    }
    const extreme = [_]f64{ -1.7e308, 4, -1.6e308, 8 };
    try std.testing.expectEqual(@as(f64, 8), k.zTable(S, 2, 2, 1, 1, "DCL", extreme, [_]S{.{ .v = 1.7e308 }}).v);
    // Different sample coordinates on each isoline; the selected outer line
    // contributes its inner gradient, while the discrete coordinate stays flat.
    const mixed = [_]f64{ -1, 0, 10, -1, 4, 18, 3, 1, 20, 3, 5, 32 };
    const outer_d = k.zTable(S, 4, 3, 2, 2, "DLL1LL", mixed, [_]S{ .{ .v = 1, .d = 1 }, .{ .v = 3 } });
    const inner_d = k.zTable(S, 4, 3, 2, 2, "DLL1LL", mixed, [_]S{ .{ .v = 1 }, .{ .v = 3, .d = 1 } });
    try std.testing.expectEqual(@as(f64, 26), outer_d.v);
    try std.testing.expectEqual(@as(f64, 0), outer_d.d);
    try std.testing.expectEqual(@as(f64, 3), inner_d.d);
    const outer_l = k.zTable(S, 4, 3, 2, 2, "1LLDLL", mixed, [_]S{ .{ .v = 0, .d = 1 }, .{ .v = 2, .d = 1 } });
    try std.testing.expectEqual(@as(f64, 18.5), outer_l.v);
    try std.testing.expectEqual(@as(f64, 0.5), outer_l.d);
}

test "codegen: §4.5.11 the bilinear transform is the one the emitted filter runs" {
    // `filter_kernels.zig` is spliced into the device, so what is exercised
    // here is what a device runs. The rows are a hand check of D=2 and D=3.
    const k = @import("kernels").filter_kernels;
    // §4.5.11's trapezoidal substitution `s = k(1−z⁻¹)/(1+z⁻¹)`, cleared by
    // `(1+z⁻¹)ᴰ`. Multiplied out for D = 2 that is
    //   q₀ = p₀ + p₁k + p₂k², q₁ = 2p₀ − 2p₂k², q₂ = p₀ − p₁k + p₂k²,
    // and with p = [1,2,3], k = 2 every term is dyadic, so this is exact.
    const q2 = k.zBilin(2, .{ 1.0, 2.0, 3.0 }, 2.0, 2);
    try std.testing.expectEqual([3]f64{ 17.0, -22.0, 9.0 }, q2);

    // The two evaluations of the transform that hold at EVERY degree, and the
    // reason a wrong sign in either inner loop cannot hide:
    //   z = 1  (z⁻¹ = 1)  ⇒ (1−z⁻¹) = 0, so only the i = 0 term lives: Σqⱼ = p₀·2ᴰ.
    //     That is DC gain, and it is what `zLaplace`'s `dt <= 0` arm computes the
    //     other way (`H(0) = num[0]/den[0]`); the two must agree or a filter's
    //     operating point disagrees with its first transient step.
    //   z = −1 (z⁻¹ = −1) ⇒ (1+z⁻¹) = 0, so only i = D lives: Σ(−1)ʲqⱼ = p_D·kᴰ·2ᴰ.
    const p3 = [4]f64{ 1.5, -2.0, 0.25, 4.0 };
    inline for (.{ 1.0, 2.0, 8.0 }) |kk| {
        const q3 = k.zBilin(3, p3, kk, 3);
        var dc: f64 = 0.0;
        var ny: f64 = 0.0;
        for (q3, 0..) |c, j| {
            dc += c;
            ny += if (j % 2 == 0) c else -c;
        }
        try std.testing.expectApproxEqRel(p3[0] * 8.0, dc, 1e-12);
        try std.testing.expectApproxEqRel(p3[3] * kk * kk * kk * 8.0, ny, 1e-12);
    }
    // D = 0 is a bare gain: no substitution to make, nothing to clear.
    try std.testing.expectEqual([1]f64{7.0}, k.zBilin(0, .{7.0}, 3.0, 0));
}

test "codegen: §4.5.15 the emitted limiters are the ones the annex E fixtures assert" {
    // `limit_kernels.zig` is spliced into every device with an honoured
    // `$limit`, so the shapes pinned here are the shapes that run there. The
    // testbench never calls `D.limit`, so no fixture executes them.
    //
    // §4.5.15 leaves the algorithm implementation-defined; what the LRM does fix
    // is §9.17.3's "when the simulator has converged, the return value of the
    // $limit() function is the value of the access function reference". Every
    // TRANSPARENCY row below is that sentence, and it is also what makes
    // `cg_limit.emitClamp`'s `if (vl != vn) ok = false;` a truthful convergence
    // flag rather than a permanent `false`. The rest are ngspice `devsup.c`.
    const k = @import("kernels").limit_kernels;
    const vt = 0.025852; // kT/q at 300 K, the `$vt` every junction model passes
    const vcrit = 0.6;

    // TRANSPARENCY. A bias below `vcrit` is returned BIT-identically; this is
    // the row `annex_e_spice/limit_pnj.va` asserts through the device.
    try std.testing.expectEqual(@as(f64, 0.3), k.zPnjlim(0.3, 0.3, vt, vcrit));
    // `DEVpnjlim` damps only past `vcrit` AND past a two-`vt` step; the damped
    // answer lands strictly between the two iterates, so the clamp pulls the
    // step back without reversing it. (0.6255 V here, but the bracket is the
    // claim: a sign slip in `vold ± vt*(2+log(…))` leaves it.)
    const damped = k.zPnjlim(1.0, 0.5, vt, vcrit);
    try std.testing.expect(damped > 0.5 and damped < 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6254615), damped, 1e-7);
    // Cold start: `vold <= 0` has no exponential to step back along, so the
    // answer is the logarithmic one, `vt*ln(vnew/vt)`, far below `vnew`.
    try std.testing.expectApproxEqAbs(@as(f64, 0.094499), k.zPnjlim(1.0, 0.0, vt, vcrit), 1e-6);
    // Reverse bias is FLOORED, and the two floors are different formulas:
    // `-vold-1` from a forward-biased previous iterate, `2*vold-1` from a
    // reverse-biased one. A swap passes at vold = -1 and nowhere else.
    try std.testing.expectEqual(@as(f64, -1.5), k.zPnjlim(-5.0, 0.5, vt, vcrit));
    try std.testing.expectEqual(@as(f64, -1.4), k.zPnjlim(-5.0, -0.2, vt, vcrit));
    try std.testing.expectEqual(@as(f64, -1.0), k.zPnjlim(-1.0, 0.5, vt, vcrit)); // above the floor: transparent

    // TRANSPARENCY, `limit_fet.va`'s digits exactly: vnew = vold = 0.3, vth = 0.7.
    try std.testing.expectEqual(@as(f64, 0.3), k.zFetlim(0.3, 0.3, 0.7));
    // `DEVfetlim` off-region (`vold < vto`): turning on stops at `vto+0.5`,
    // turning off steps by at most `vtsthi = |2(vold-vto)|+2` = 3.4 V here.
    try std.testing.expectEqual(@as(f64, 1.2), k.zFetlim(5.0, 0.0, 0.7));
    try std.testing.expectEqual(@as(f64, -3.4), k.zFetlim(-5.0, 0.0, 0.7));
    // Middle region (`vto <= vold < vto+3.5`): a window of `vto-0.5 … vto+4`.
    // (`vto ± c` is computed, not written, so these two are the only rows here
    // that cannot be spelled as an exact literal.)
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), k.zFetlim(10.0, 1.0, 0.7), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), k.zFetlim(-10.0, 1.0, 0.7), 1e-15);

    // TRANSPARENCY, `limit_vds.va`'s digits: 0.4 V from a cold 0 V is inside
    // both of `DEVlimvds`'s low-`vold` bounds (+4 rising, −0.5 falling).
    try std.testing.expectEqual(@as(f64, 0.4), k.zLimvds(0.4, 0.0));
    try std.testing.expectEqual(@as(f64, 4.0), k.zLimvds(10.0, 0.0));
    try std.testing.expectEqual(@as(f64, -0.5), k.zLimvds(-3.0, 0.0));
    // Past 3.5 V the bound becomes multiplicative going up (`3*vold+2`) and a
    // floor of 2 V coming down: the fixture header's "only a previous iterate
    // at or above 3.5 V would answer max(0.4, 2) = 2".
    try std.testing.expectEqual(@as(f64, 14.0), k.zLimvds(100.0, 4.0));
    try std.testing.expectEqual(@as(f64, 2.0), k.zLimvds(1.0, 4.0));
}

test "codegen: §4.5.15 signed $limit clamps sign*v and seeds sign*vcrit" {
    // The frame-sign extension: `$limit(V(a,b), "pnjlim", vt, vc, type)`.
    // devsup.c limiters assume forward = positive; a PNP passes type = -1 and
    // the emitted clamp must (1) run the kernel on sg·v, (2) hand back
    // sg·result, (3) seed the junction at sign·vcrit. The unsigned spelling
    // has no sg indirection.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  parameter real type = -1.0;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc, type) - V(p)) / 1.0;
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    // The ±1 is recovered once per distinct sign at the top of `limit` and
    // each clamp aliases it: every clamp on a MOSFET reads the same `type`.
    try std.testing.expect(std.mem.find(u8, s, "const zsg__") != null);
    try std.testing.expect(std.mem.find(u8, s, " < 0) -1.0 else 1.0;") != null);
    try std.testing.expect(std.mem.find(u8, s, "const sg: f64 = zsg__") != null);
    try std.testing.expect(std.mem.find(u8, s, "sg * zPnjlim(sg * vn, sg * vo") != null);
    // The live sets. The probe is `V(mid)` (mid against §1.3.1.1 ground, not
    // against the port), so `mid` (bit 1) is the only unknown either half
    // touches and `p` (bit 0) stays clear in both.
    try std.testing.expect(std.mem.find(u8, s, "pub const limit_reads: u64 = 0x2;") != null);
    try std.testing.expect(std.mem.find(u8, s, "pub const limit_writes: u64 = 0x2;") != null);
    // Seed picks the branch by the sign's runtime value.
    try std.testing.expect(std.mem.find(u8, s, "s[@intFromEnum(U.mid)] = if (") != null);
    // Convergence verdict unchanged: pnjlim still reports through `ok`.
    try std.testing.expect(std.mem.find(u8, s, "if (vl != vn) ok = false;") != null);

    // Unsigned control: no sg anywhere.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc) - V(p)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s2, "sg") == null);
    try std.testing.expect(std.mem.find(u8, s2, "zPnjlim(vn, vo") != null);
}

test "codegen: §4.5.15 a fetlimds pair + limvds emit ngspice's mode ladder" {
    // The mos-family frame swap (mos1load.c:351-373): both gate legs spelled
    // "fetlimds" plus a limvds on the channel emit ONE rung that branches on
    // the sign of the OLD vds, fetlims only the controlling leg, and gives
    // limvds mode-dependent write targets: `di` in normal mode (vgs is
    // preserved, vgd derived), `si` in inverse mode (`vds =
    // -DEVlimvds(-vds,-vdso)`, vgd preserved, vgs derived).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(g, d, s);
        \\  inout g, d, s; electrical g, d, s, di, si;
        \\  parameter real vto = 0.7;
        \\  parameter real type = -1.0;
        \\  real vgs, vgd, vds;
        \\  analog begin
        \\    vgs = type * $limit(V(g, si), "fetlimds", type * vto, type);
        \\    vgd = type * $limit(V(g, di), "fetlimds", type * vto, type);
        \\    vds = type * $limit(V(di, si), "limvds", type);
        \\    I(d, di) <+ (V(d) - V(di)) / 10.0;
        \\    I(s, si) <+ (V(s) - V(si)) / 10.0;
        \\    I(di, si) <+ 1e-3 * (vgs + vgd + vds);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    // The branch condition is the limiter's own memory, in the device frame.
    try std.testing.expect(std.mem.find(u8, s, "const vdso = old[@intFromEnum(U.di)] - old[@intFromEnum(U.si)];") != null);
    try std.testing.expect(std.mem.find(u8, s, "if (sgt * vdso >= 0.0) {") != null);
    // Normal arm: +frame limvds, correction to the drain side.
    try std.testing.expect(std.mem.find(u8, s, "const dl = sgt * zLimvds(sgt * dn, sgt * vdso);") != null);
    try std.testing.expect(std.mem.find(u8, s, "x[@intFromEnum(U.di)] += dl - dn;") != null);
    // Inverse arm: −frame limvds, correction to the source side.
    try std.testing.expect(std.mem.find(u8, s, "const dl = -sgt * zLimvds(-sgt * dn, -sgt * vdso);") != null);
    try std.testing.expect(std.mem.find(u8, s, "x[@intFromEnum(U.si)] -= dl - dn;") != null);
    // The limvds site is CLAIMED by the ladder: no standalone clamp shape.
    try std.testing.expect(std.mem.find(u8, s, "zLimvds(sg * vn") == null);
    try std.testing.expect(std.mem.find(u8, s, "zLimvds(vn, vo") == null);

    // A dangling fetlimds (no second leg, no limvds) is declined whole, not
    // half-honoured as a static clamp.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m2(g, s);
        \\  inout g, s; electrical g, s, si;
        \\  parameter real vto = 0.7;
        \\  analog I(si, s) <+ ($limit(V(g, si), "fetlimds", vto) - V(s)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(limitDeclined(&h2, "no complete mode ladder"));
    try std.testing.expect(std.mem.find(u8, s2, "pub fn limit(") == null);
}

test "codegen: §9.17.3 a solve-dependent $limit argument is evaluated at `old`" {
    // ngspice fetlims against the `von` its PREVIOUS load stored
    // (mos1load.c:351, :535), and §9.17.3 leaves the returned value to the
    // simulator. So `limit` runs the slice of the core that computes its
    // arguments at `old`, the previous iterate's limited point, never at the
    // unlimited `cur`. The slice returns `von` alone: the residuals stay in
    // the core, and `limit` never pays for them.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(g, s, d);
        \\  inout g, s, d; electrical g, s, d, si;
        \\  real von;
        \\  analog begin
        \\    von = 0.5 + 0.1 * V(d, si);
        \\    I(si, s) <+ ($limit(V(g, si), "fetlim", von) - V(s)) / 1.0;
        \\    I(d, si) <+ V(d, si) / 1e3;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "m = m__common__core__limit(S, zVals(S, &old), model, inst, sim)") != null);
    try std.testing.expect(std.mem.find(u8, s, "for (cur, 0..)") == null);
    const at = std.mem.find(u8, s, "fn m__common__core__limit(").?;
    const sig = s[at..std.mem.findPos(u8, s, at, "} {").?];
    try std.testing.expect(std.mem.find(u8, sig, "f0:") != null);
    try std.testing.expect(std.mem.find(u8, sig, "f1:") == null);
}

test "codegen: §9.17.3 two pnjlimds legs + limvds emit ngspice's bulk rung" {
    // mos1load.c:376-384: after the ladder, pnjlim ONE junction chosen by the
    // LIMITED vds, from its raw value, and move only the bulk: a port here, written
    // anyway (a host that masks ports only loses the clamp).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(d, g, s, b);
        \\  inout d, g, s, b; electrical d, g, s, b, di, si;
        \\  parameter real vt = 0.025, vcs = 0.6, vcd = 0.61, type = -1.0;
        \\  real vds, vbs, vbd;
        \\  analog begin
        \\    vds = $limit(V(di, si), "limvds", type);
        \\    vbs = $limit(V(b, si), "pnjlimds", vt, vcs, type);
        \\    vbd = $limit(V(b, di), "pnjlimds", vt, vcd, type);
        \\    I(d, di) <+ V(d, di) / 10.0;
        \\    I(s, si) <+ V(s, si) / 10.0;
        \\    I(di, si) <+ 1e-3 * vds;
        \\    I(b, si) <+ 1e-14 * (limexp(vbs / vt) - 1.0);
        \\    I(b, di) <+ 1e-14 * (limexp(vbd / vt) - 1.0);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "if (sgt * (x[@intFromEnum(U.di)] - x[@intFromEnum(U.si)]) >= 0.0) {") != null);
    try std.testing.expect(std.mem.find(u8, s, "const vn = cur[@intFromEnum(U.b)] - cur[@intFromEnum(U.si)];") != null);
    try std.testing.expect(std.mem.find(u8, s, "x[@intFromEnum(U.b)] = x[@intFromEnum(U.si)] + vl;") != null);
    try std.testing.expect(std.mem.find(u8, s, "x[@intFromEnum(U.b)] = x[@intFromEnum(U.di)] + vl;") != null);
    // Neither channel node takes a junction's correction: the one write to
    // si is the flat limvds clamp's own.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "x[@intFromEnum(U.si)] -= vl - vn;"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, s, "x[@intFromEnum(U.di)] -= vl - vn;"));
    // U = d, g, s, b, di, si: the rung writes b (bit 3), limvds si (bit 5).
    try std.testing.expect(std.mem.find(u8, s, "pub const limit_writes: u64 = 0x28;") != null);
    for (0..h.bag.count()) |i| try std.testing.expect(h.bag.at(i).code != .W0853);
}

/// Does the bag carry a W0853 whose message contains `why`?
fn limitDeclined(h: *Harness, why: []const u8) bool {
    for (0..h.bag.count()) |i| {
        const e = h.bag.at(i);
        if (e.code == .W0853 and std.mem.find(u8, e.message, why) != null) return true;
    }
    return false;
}

test "codegen: §9.17.3 a declined $limit is W0853 naming why, an honoured one is silent" {
    // §9.17.3 lets the simulator return the probe unchanged, so every one of
    // these compiles; what the warning adds is the reason, so a model that
    // asked for limiting learns it did not get it.
    const cases = [_]struct { body: []const u8, why: ?[]const u8 }{
        .{ .body = "$limit(V(a, c), \"pnjlim\", $vt, 0.6)", .why = null },
        .{ .body = "$limit(V(a, c), \"nosuchlim\", 0.6)", .why = "names no algorithm VerA implements" },
        .{ .body = "$limit(V(a, c))", .why = "names no algorithm, and VerA's own choice" },
        .{ .body = "$limit(I(a, c), \"pnjlim\", $vt, 0.6)", .why = "not a §4.4 potential probe" },
        .{ .body = "(V(a) > 0.0 ? $limit(V(a, c), \"pnjlim\", $vt, 0.6) : V(a, c))", .why = "under an `if`" },
        .{ .body = "$limit(V(p, n), \"pnjlim\", $vt, 0.6)", .why = "both nets are §6.5 ports" },
        .{ .body = "$limit(V(a, c), \"steplim\")", .why = "too few arguments" },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module d(p, n);
            \\  inout p, n; electrical p, n, a, c;
            \\  real v;
            \\  analog begin
            \\    I(p, a) <+ V(p, a) / 10.0;
            \\    I(c, n) <+ V(c, n) / 10.0;
            \\    v = {s};
            \\    I(a, c) <+ 1e-14 * (limexp(v / $vt) - 1.0);
            \\  end
            \\endmodule
        , .{c.body});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.find(u8, out, "@compileError") == null);
        if (c.why) |why| {
            try std.testing.expect(limitDeclined(&h, why));
            try std.testing.expect(std.mem.find(u8, out, "pub fn limit(") == null);
        } else {
            for (0..h.bag.count()) |i| try std.testing.expect(h.bag.at(i).code != .W0853);
            try std.testing.expect(std.mem.find(u8, out, "pub fn limit(") != null);
        }
    }
}

test "codegen: §3.2 a held slot only a card-varying write could need is dropped" {
    // `held.prune`: under a parameter the write runs on every evaluation or on
    // none, so the held value is never seen; under a probe it is.
    const cases = [_]struct { cond: []const u8, held: usize }{
        .{ .cond = "g > 0", .held = 0 },
        .{ .cond = "V(p) > 0", .held = 1 },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p; electrical p;
            \\  parameter real g = 1.0;
            \\  real x, y;
            \\  analog begin
            \\    if ({s}) x = 2.0;
            \\    y = x;
            \\    I(p) <+ y * V(p);
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        try std.testing.expectEqual(1, h.lowered.held_vars.items.len);
        if (try @import("prove").held.prune(h.arena_state.allocator(), &h.mir, &h.lowered)) |keep| Lower.dropHeld(&h.lowered, keep);
        try std.testing.expectEqual(c.held, h.lowered.held_vars.items.len);
        _ = try h.gen(std.testing.allocator); // and the device still generates
    }
}

test "codegen: §5.2.1 an `analog initial` variable is a setup root, not a per-evaluation select" {
    // §3.2 holds `g` (an `analog initial` write the main block reads), ifconv
    // leaves the first-point branch alone, and setup's initial-only rule then
    // computes `g` once: the core reads `su`, never the flag.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ai(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog initial g = 2.0;
        \\  analog I(p, n) <+ g * V(p, n);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectEqual(Lower.HeldVar.Why.retained, h.lowered.held_vars.items[0].why);
    _ = try ifconv.run(h.arena_state.allocator(), &h.mir, .pure, null);
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "model.su.r[0] = ") != null);
    try std.testing.expect(std.mem.find(u8, s, "if (inst.is_analog_initial)") == null);
}

test "codegen: cross-fed held state is what stateCtl's query compares" {
    // The hysteresis-FSM hook (contract.zig StateCtlOp): a module whose held
    // state is written from cross edges answers `query` from its accepted
    // twin, so the transient can land its conductance flip sharp. A held
    // variable fed only by a timer is reverted but never queried: breakpoints
    // already place those edges.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n, c);
        \\  inout p, n, c; electrical p, n, c;
        \\  integer latched;
        \\  analog begin
        \\    @(cross(V(c) - 0.5, +1)) latched = 1;
        \\    @(cross(V(c) - 0.5, -1)) latched = 0;
        \\    I(p, n) <+ ((latched > 0) ? 1.0 : 1.0e-9) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "pub fn stateCtl(") != null);
    try std.testing.expect(std.mem.find(u8, s, "return (inst.sw__held__latched != state.sw__held__latched);") != null);
    try std.testing.expect(std.mem.find(u8, s, "__cross__prev = state.") != null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tmr(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer armed;
        \\  analog begin
        \\    @(timer(1n)) armed = 1;
        \\    I(p, n) <+ ((armed > 0) ? 1.0 : 1.0e-9) * V(p, n);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s2, "if (op == .query) {\n        return false;") != null);
    try std.testing.expect(std.mem.find(u8, s2, "inst.tmr__held__armed = state.tmr__held__armed;") != null);
}

test "codegen: an assert-form idt's offset is committed and reverted by stateCtl" {
    // §4.5.4 `updateState` latches `<n>__off` in place; a rejected step must
    // get the accepted one back (a04_idt_hold_revert_host.zig runs it).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(a, n);
        \\  inout a, n; electrical a, n;
        \\  analog I(a, n) <+ 1e-3 * idt(1e9, 7.0, V(a, n));
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "pub fn stateCtl(") != null);
    try std.testing.expect(std.mem.find(u8, s, "state.m__analog_op__idt__off = inst.m__analog_op__idt__off;") != null);
    try std.testing.expect(std.mem.find(u8, s, "inst.m__analog_op__idt__off = state.m__analog_op__idt__off;") != null);
}

test "codegen: a $prev-only model still gets latch staging and commit" {
    // `$prev` plants a path_prev site with NO path_acc sibling (the reactive
    // lowering always pairs them, a source site arrives alone), so every gate
    // on the latch machinery must key on pathLatches(), not acc_lo; otherwise
    // `pb__` silently stays 0.0 here.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module avg(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 + 0.1 * V(p, n);
        \\    I(p, n) <+ 0.5 * (g + $prev(g)) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "zInst(S, inst, \"pb__0\")") != null);
    try std.testing.expect(std.mem.find(u8, s, "state.wb__0 = ") != null); // updateState stages
    try std.testing.expect(std.mem.find(u8, s, "inst.pb__0 = state.wb__0;") != null); // commit latches
    try std.testing.expect(std.mem.find(u8, s, "pub fn stateCtl(") != null);

    // $prev of a value with no unknown dependence is the value itself: no
    // latch, no hook, byte-identical to writing the parameter.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module k(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real c = 2.0;
        \\  analog I(p, n) <+ $prev(c) * V(p, n);
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s2, "pb__") == null);
    try std.testing.expect(std.mem.find(u8, s2, "pub fn stateCtl(") == null);
}

test "codegen: a batch reads each point's own Instance, or the device is not batch_ok" {
    // The batch key is the Model row and the SimState; each point has its own
    // Instance. A held value or a `$prev` latch reads per point (`zInst`,
    // `batch_inst`); operator history no point can carry (absdelay's samples)
    // drops `batch_ok`.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module k(p, n);
        \\  inout p, n; electrical p, n; real h;
        \\  analog begin
        \\    @(initial_step) h = V(p, n);
        \\    I(p, n) <+ h * V(p, n) + 1e-3 * $prev(V(p, n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "zInst(S, inst, \"k__held__h\")") != null);
    try std.testing.expect(std.mem.find(u8, s, "pub const batch_ok = true;") != null);
    try std.testing.expect(std.mem.find(u8, s, "pub const batch_inst = true;") != null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module k(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ absdelay(V(p, n), 1n);
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s2, "pub const batch_ok") == null);
}

test "codegen: every .val()-collapsing helper is on the lane-pin ledger" {
    // The `batch_ok` promise is only as good as its pins, which are
    // hand-placed at emission sites, and a forgotten one ships a false
    // promise. So any helper in the emitted math/ops templates whose body
    // reads `.val(` must be listed here: either its emission site calls
    // `pinLanes`, or it steers only on lane-uniform state (dt, ic, inst
    // history, never x), or it is a lead-protocol decision whose emission
    // site calls `leadLanes` (a batch family's `decide` hooks replace it).
    const pinned = [_][]const u8{
        "zPow",   "zHypot", "zFmod",    "zFloor", "zCeil",
        "zAtan2", "zWrap",  "zLimitUf",
        // §4.3 the C-function values (#60): `opcode_zig` pins their rows.
        "zLog10", "zAsin",
        "zAcos",  "zAsinh", "zAcosh",   "zAtanh",
    };
    const uniform = [_][]const u8{
        "zIdt",        "zIdtAcc",   "zIdtmod", "zSlew",   "zTransFrac",
        "zTransition", "zAbsdelay", "zTan",    "zPadInt",
        // §4.3.2 read `.val()` only for `zDomain`'s report, never to steer.
        "zSqrtD",
        "zLnD",        "zLn1pD",    "zLog10D", "zPowK",
    };
    const lead = [_][]const u8{ "zCmp", "zRoundI", "zStrip", "zMulP", "zAddP", "zSubP" };
    const text = gen_kernel_text.math_txt ++ gen_kernel_text.ops_txt;
    var it = std.mem.splitSequence(u8, text, "\nfn ");
    _ = it.first(); // preamble before the first helper
    while (it.next()) |chunk| {
        const paren = std.mem.findScalar(u8, chunk, '(') orelse continue;
        const fn_name = chunk[0..paren];
        // Body = up to the next helper (the split already bounded it).
        if (std.mem.find(u8, chunk, ".val(") == null) continue;
        for (pinned) |p| {
            if (std.mem.eql(u8, fn_name, p)) break;
        } else for (uniform) |u| {
            if (std.mem.eql(u8, fn_name, u)) break;
        } else for (lead) |l| {
            if (std.mem.eql(u8, fn_name, l)) break;
        } else {
            std.debug.print("helper `{s}` reads .val() but is on neither ledger\n", .{fn_name});
            return error.TestUnexpectedResult;
        }
    }
}

test "codegen: §4.5.15 only pnjlim reports non-convergence" {
    // The kernels above are pure functions; this pins the one line of
    // `cg_limit.emitClamp` that turns `zPnjlim`'s transparency into the
    // contract's `converged` verdict. ngspice sets `icheck` from `DEVpnjlim`
    // alone, and exactly on the paths where it moved `vnew`, so "the value
    // changed" IS the flag. Nothing executes `D.limit` (see the test above), so
    // the emitted text is the only place this claim is visible.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc) - V(p)) / 1.0;
        \\endmodule
    , &h);
    defer h.deinit();
    const pnj = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, pnj, "if (vl != vn) ok = false;") != null);
    try std.testing.expect(std.mem.find(u8, pnj, ".converged = ok }") != null);

    // fetlim clamps too, but its clamp is trajectory shaping and not a statement
    // about the residual, so the device reports converged and carries no `ok`
    // at all. An unconditional `var ok` would be an unused-variable compile
    // error in the emitted device, which no fixture would ever reach.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  analog I(mid, p) <+ ($limit(V(mid), "fetlim", 0.7) - V(p)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const fet = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, fet, "zFetlim(") != null);
    try std.testing.expect(std.mem.find(u8, fet, "var ok = true;") == null);
    try std.testing.expect(std.mem.find(u8, fet, "vl != vn") == null);
    try std.testing.expect(std.mem.find(u8, fet, ".converged = true }") != null);
}

test "codegen: declared integer conversions reach real field initializers" {
    // Fixture execution calls derive(); these assertions also cover Model{}
    // before derivation, so correct derive code cannot hide an incorrect seed.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module converted(p);
        \\  inout p; electrical p;
        \\  parameter integer a = 4294967297.0;
        \\  parameter real b = a / 2;
        \\  parameter integer aa[1:0] = '{4294967297.0,4294967299.0};
        \\  parameter real c = aa[1] / 2;
        \\  parameter real d = aa[0] / 2;
        \\  analog I(p) <+ (b+c+d) * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const generated = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, generated, "b: f64 = 0.0,") != null);
    try std.testing.expect(std.mem.find(u8, generated, "c: f64 = 0.0,") != null);
    try std.testing.expect(std.mem.find(u8, generated, "d: f64 = 1.0,") != null);
}

test "codegen: unused distributions retain validation without forcing draw loops" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p,n);
        \\  inout p,n; electrical p,n;
        \\  integer seed;
        \\  real unused;
        \\  analog begin
        \\    seed = 7;
        \\    unused = $rdist_chi_square(seed,2147483647);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The draw functions are defined, but an unused variate and seed do not
    // introduce a billion-iteration draw. Only the required check is invoked.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "zRngChiSquare("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "zRngChiSquareNext("));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "zRngCheck("));
}

test "codegen: §3.6.3.2 a net initializer is exported as a nodeset, not as a value" {
    // The clause's own first example, `electrical a = 5.0;`, plus the two
    // spellings it does not print: the initializer on a net that is also a
    // module PORT, and one written over a parameter (§3.4 makes a parameter
    // reference a constant_expression, so `= vstart` is legal).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ns(p, n);
        \\  inout p, n;
        \\  electrical p = 1.5;
        \\  electrical n;
        \\  parameter real vstart = 2.25;
        \\  electrical mid = vstart;
        \\  analog begin
        \\    I(p, mid) <+ V(p, mid);
        \\    I(mid, n) <+ V(mid, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One optional table over U, in U's order: port `p`, port `n`, net `mid`.
    // `n` is null and not 0.0: "a null value ... indicates that no nodeset
    // value is being specified", and a host must be able to tell the two apart.
    try std.testing.expect(std.mem.find(u8, src, "pub const u_nodeset = [n_u]?f64{\n    1.5,\n    null,\n    2.25,\n};") != null);

    // A NODESET, so nothing in the residual may read it: `eval` is a function
    // of x alone, and a starting point that leaked into it would be a clamp.
    const at = std.mem.find(u8, src, "inline fn zResidual(").?;
    try std.testing.expect(std.mem.find(u8, src[at..], "u_nodeset") == null);
}

test "codegen: §3.6.3.2 a module with no net initializer exports no nodeset table" {
    // The decl is optional and its absence means "this module states no
    // opinion"; a table of nulls would say the same in more bytes.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module plain(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ V(p, n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "u_nodeset") == null);
}

test "codegen: the setup split — invariant values are computed by setup and read by eval" {
    // `$param_given(gain) ? gain : 0.0` depends on the card alone, so it is a
    // setup root: `setup` computes it with the host's value scalar V, the core
    // reads `model.su` (asserting in Debug that setup ran), and no
    // `precompute`, prefix latch or `P` scalar is emitted.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module pg(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real gain = 1.0;
        \\  analog I(p,n) <+ ($param_given(gain) ? gain : 0.0) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "pub const Setup = struct {") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub fn setup(comptime V: type, model: *Model) void {") != null);
    try std.testing.expect(std.mem.find(u8, src, "model.su.r[0] = (") != null);
    try std.testing.expect(std.mem.find(u8, src, ".scale(model.su.r[0])") != null);
    try std.testing.expect(std.mem.find(u8, src, "if (std.debug.runtime_safety and contract.validating) std.debug.assert(model.su_ok);") != null);
    try std.testing.expect(std.mem.find(u8, src, "pub const setup_simparams = [_][]const u8{};") != null);
    try std.testing.expect(std.mem.find(u8, src, "precompute") == null);
    try std.testing.expect(std.mem.find(u8, src, "hp_ok") == null);
    try std.testing.expect(std.mem.find(u8, src, "const P = struct {") == null);
}

test "codegen: the setup split computes a probe-guarded card value, and lists its $simparams" {
    // ln(r) runs only on the `V(p,n) > 0` arm, a branch on the solve: its
    // block is not placeable, but ln cannot fault (a negative r is NaN,
    // read only on the arm), so `setup` computes it (prove/setup.zig
    // `speculable`) and the core reads the root.
    // `$simparam("gmin")` is a Table 9-27 name other than `iteration`, so it
    // is invariant and `setup_simparams` names it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module gd(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real r = 2.0;
        \\  real x;
        \\  analog begin
        \\    if (V(p, n) > 0.0) x = ln(r); else x = 0.0;
        \\    I(p, n) <+ (x + $simparam("gmin") * r) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const su = src[std.mem.find(u8, src, "pub fn setup(").?..];
    const su_end = std.mem.find(u8, su, "\n}\n").?;
    try std.testing.expect(std.mem.find(u8, su[0..su_end], "log") != null);
    // Speculated, so unchecked (`Setup.spec`): with r = -1 on the card and
    // the arm never taken, no evaluation runs ln(r), so §4.3.2 has no error
    // to report (#59).
    try std.testing.expect(std.mem.find(u8, su[0..su_end], ".log()") != null);
    try std.testing.expect(std.mem.find(u8, su[0..su_end], "zLnD(") == null);
    const core_at = std.mem.find(u8, src, "__common__core(comptime S").?;
    try std.testing.expect(std.mem.find(u8, src[core_at..], "log") == null);
    try std.testing.expect(std.mem.find(u8, src, "pub const setup_simparams = [_][]const u8{ \"gmin\" };") != null);
}

test "codegen: setup stores a card expression written twice once, and a 0/1 flag as a bool" {
    // `exp(r)` is two MIR values with one op over one operand: one field.
    // `on > 0` is a §4.2.5 comparison, 0 or 1: a byte, not an i64.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dd(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real r = 2.0;
        \\  parameter integer on = 1;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) * exp(r);
        \\    if (on > 0) I(p, n) <+ V(p, n) * V(p, n) * exp(r);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "    r: [1]f64 = @splat(" ++ gen_kernel_text.nan_lit ++ "),\n    /// One bit per invariant §4.2.5/§4.2.8 condition `eval` branches on.\n    b: std.StaticBitSet(1) = .empty,\n};") != null);
    try std.testing.expect(std.mem.find(u8, src, "model.su.b.setValue(0, (") != null);
}

test "codegen: §5.10.2 a held variable written only by @(initial_step) is computed once, by setup" {
    // Every write of `g` is in an unqualified `@(initial_step)` with a
    // card-only value, so `g` is initial-only (prove/setup.zig's header): its
    // merge phi is a setup root and the core reads it with no initial-step
    // test at all.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module istep(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real r = 2.0;
        \\  real g;
        \\  analog begin
        \\    @(initial_step) g = 1.0 / ln(r);
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const su = src[std.mem.find(u8, src, "pub fn setup(").?..];
    // `zLnD` where setup runs ln on its own path, the bare `.log()` where it
    // speculates it (`Setup.spec`): either is setup computing it.
    const su_body = su[0..std.mem.find(u8, su, "\n}\n").?];
    try std.testing.expect(std.mem.find(u8, su_body, "zLnD(") != null or std.mem.find(u8, su_body, ".log()") != null);
    const core = src[std.mem.find(u8, src, "__common__core(comptime S").?..];
    const body = core[0..std.mem.find(u8, core, "\n}\n").?];
    try std.testing.expect(std.mem.find(u8, body, ".scale(model.su.r[0])") != null);
    try std.testing.expect(std.mem.find(u8, body, "is_initial_step") == null);
    try std.testing.expect(std.mem.find(u8, body, "log") == null);
}

/// `setup`'s body, up to its closing brace.
fn setupBody(src: []const u8) []const u8 {
    const su = src[std.mem.find(u8, src, "pub fn setup(").?..];
    return su[0..std.mem.find(u8, su, "\n}\n").?];
}

test "codegen: setup's live exits share one copy of the root stores" {
    // An invariant branch reaches the per-eval loop's stop on one arm and the
    // function exit on the other: two live exits, which leave `zs_done` and
    // store the six roots once after it. The dead half (an exit only a false
    // `zs_stop` reaches stores nothing) needs nested per-eval loops, as in
    // hisimhv_va, which a small module does not reproduce.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module zm(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real r = 2.0;
        \\  real s, a1, a2, a3, a4, a5, a6;
        \\  analog begin
        \\    s = 0.0;
        \\    if (r > 1.0) begin
        \\      while (V(p, n) > s) s = s + 0.1;
        \\    end else begin
        \\      a1 = ln(r + 1.0); a2 = ln(r + 2.0); a3 = ln(r + 3.0);
        \\      a4 = ln(r + 4.0); a5 = ln(r + 5.0); a6 = ln(r + 6.0);
        \\      if (V(p, n) > 1.0) s = a1 * V(p, n); else s = a2;
        \\    end
        \\    I(p, n) <+ s + (((((a1 * V(p, n) + a2) * V(p, n) + a3) * V(p, n) + a4) * V(p, n) + a5) * V(p, n) + a6) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const su = setupBody(src);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, su, "model.su.r[0] = "));
    try std.testing.expect(std.mem.find(u8, su, "if (zs_stop) break :zs_done;") != null);
}

test "codegen: §5.6.5 a collapsible short's flow column leaves deriv_reads behind a guarded jac_const" {
    // `rs` alone decides the 0 V arm, so the retention flag is a function of
    // the card: `derive` publishes it as a Model field, the ±1 KCL stamps of
    // the branch current become `jac_const` entries guarded by that field,
    // and the flow unknown needs no derivative lane (contract.JacWhen).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n);
        \\  inout p, n; electrical p, n, ai;
        \\  parameter real rs = 1000.0;
        \\  analog begin
        \\    I(ai, n) <+ V(ai, n) / 1000.0;
        \\    if (rs > 0.0) I(p, ai) <+ V(p, ai) / rs;
        \\    else V(p, ai) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const field = "flowZ28pZ2caiZ29__retained";
    try std.testing.expect(std.mem.find(u8, src, "    " ++ field ++ ": f64 = ") != null);
    try std.testing.expect(std.mem.find(u8, src, "    model." ++ field ++ " = m.f") != null);
    try std.testing.expect(std.mem.find(u8, src, ".{ .row = .p, .col = .flowZ28pZ2caiZ29, .g = 1.0, .c = 0.0, .when = .{ .flag = \"" ++ field ++ "\", .collapse_open = true } },") != null);
    try std.testing.expect(std.mem.find(u8, src, ".{ .row = .ai, .col = .flowZ28pZ2caiZ29, .g = -1.0, .c = 0.0, .when = .{ .flag = \"" ++ field ++ "\", .collapse_open = true } },") != null);
    // p, n, ai have lanes; the flow unknown (bit 3) does not.
    try std.testing.expect(std.mem.find(u8, src, "pub const deriv_reads: u64 = 0x0000000000000007;") != null);
}

test "codegen: no embedded kernel shadows a device-level declaration" {
    // The kernel files are spliced verbatim into device.zig, beside the
    // device's own public entry points. A kernel local named like one of them
    // (`var q` in `zBilin` beside a ddt() device's `pub fn q`) is an AstGen
    // shadowing error that only a device using both shows (ESPice W element:
    // laplace_nd + ddt). AstGen every kernel against stubs of every name a
    // device or its contract surface declares.
    const gpa = std.testing.allocator;
    // Every `pub` name codegen emits at device scope, plus the contract
    // surface a host reaches by name.
    const names = [_][]const u8{
        "ac_gens",
        "batch_ok",
        "constant",
        "deriv_reads",
        "fileIo",
        "deinitInstance",
        "jac_f",
        "lane_masks",
        "limit_reads",
        "limit_writes",
        "Model",
        "mutable_eval",
        "noise_gens",
        "noise_tables",
        "n_q",
        "num_ports",
        "q_lte",
        "Setup",
        "setup_simparams",
        "State",
        "state_class",
        "systf_calls",
        "U",
        "u_abstol",
        "u_kinds",
        "u_nodeset",
        "decl_meta",
        "op_vars",
        "vpi_contrib_access",
        "vpi_share_row",
        "acceptQ",
        "acStim",
        "acDyn",
        "advanceIteration",
        "checkConvergence",
        "collapse",
        "delays",
        "derive",
        "display",
        "eval",
        "evalQ",
        "initState",
        "limit",
        "nextBreakpoint",
        "noisePsd",
        "noiseTablePoints",
        "opVars",
        "pendingBreakpoint",
        "q",
        "setup",
        "stateCtl",
        "updateState",
        "vpiContribs",
        "vpiShares",
        "core",
        "n_u",
        "Instance",
        "InstancePtr",
        "jac_pattern",
    };
    var stubs: std.ArrayList(u8) = .empty;
    defer stubs.deinit(gpa);
    try stubs.appendSlice(gpa, "const contract = @import(\"contract\");\nconst Self = @This();\n");
    for (names) |n| try stubs.print(gpa, "pub fn {s}() void {{}}\n", .{n});
    const kernels = [_][]const u8{
        gen_kernel_text.timer_txt, gen_kernel_text.str_txt,  gen_kernel_text.rng_txt,
        gen_kernel_text.table_txt, gen_kernel_text.file_txt, gen_kernel_text.limit_txt,
        gen_kernel_text.filt_txt,
    };
    for (kernels) |k| {
        const has_std = std.mem.find(u8, k, "const std = @import(\"std\");") != null;
        const file = try std.mem.concatWithSentinel(gpa, u8, &.{
            if (has_std) "" else "const std = @import(\"std\");\n", stubs.items, k,
        }, 0);
        defer gpa.free(file);
        var tree = try std.zig.Ast.parse(gpa, file, .{ .mode = .zig });
        defer tree.deinit(gpa);
        var zir = try std.zig.AstGen.generate(gpa, tree);
        defer zir.deinit(gpa);
        if (zir.hasCompileErrors()) std.debug.print("{s}\n", .{k[0..@min(k.len, 120)]});
        try std.testing.expect(!zir.hasCompileErrors());
    }
}

test "codegen: a device with laplace_nd and ddt passes AstGen" {
    // ESPice's W element: a filter (whose kernels are spliced in) beside a
    // charge site (which gives the device `pub fn q`).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module wmix(p, n, cp, cn);
        \\  inout p, n, cp, cn;
        \\  electrical p, n, cp, cn;
        \\  parameter real num[0:2] = '{1.0, 0.0, 0.0};
        \\  parameter real den[0:2] = '{1.0, 1e-9, 1e-19};
        \\  analog begin
        \\    V(p, n) <+ laplace_nd(V(cp, cn), num, den);
        \\    I(cp, cn) <+ ddt(1e-12 * V(cp, cn));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const gpa = std.testing.allocator;
    const text = try gpa.dupeSentinel(u8, try h.gen(gpa), 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.find(u8, text, "pub fn q(") != null);
    var tree = try std.zig.Ast.parse(gpa, text, .{ .mode = .zig });
    defer tree.deinit(gpa);
    var zir = try std.zig.AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);
    try std.testing.expect(!zir.hasCompileErrors());
}

// ---------------------------------------------------------------------------
// Structural oracles over a corpus of every emitter, and the defects they and
// the LRM found. The plan (test-plan, compiler domain):
//
//   bug class                          oracle                         where
//   emitted text is not Zig, or an     AstGen over device.zig, every  `expectSoundDevice`
//   unused local or parameter          `u/<key>.zig` and `h.zig`
//   survives a `_` back-patch
//   nondeterministic emission          generate twice, byte-compare   `expectSoundDevice`
//   `Output` ranges do not tile        the invariant `Output` states  `expectSoundDevice`
//   a clause read wrong                the LRM sentence, quoted       the tests below
//   a pure text transform wrong        hand-derived input -> output   setup_chunk.zig etc.
// ---------------------------------------------------------------------------

/// Fails, printing the text, when AstGen reports any error: the cheapest
/// oracle that an artifact is Zig at all (`exe.zig` owns it).
const expectAstGen = exe_tests.expectAstGen;

/// The structural contract of one source in one display mode: generation
/// is not fatal and is byte-identical when repeated; device.zig passes
/// AstGen; the unit ranges tile in order, each holding the declaration it
/// names with `unit_fn` at its keyword. For a solver device (`.drop`,
/// `.record`: the artifacts a split build compiles) every `u/<key>.zig` the
/// zigbuild would write, and `h.zig`, pass AstGen too.
fn expectSoundDevice(src: []const u8, display: codegen.Display) !void {
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    try Harness.run(gpa, src, &h);
    defer h.deinit();
    if (h.bag.failed()) {
        std.debug.print("a corpus source failed to lower:\n{s}\n", .{src});
        return error.TestUnexpectedResult;
    }
    const o = h.genWith(.{ .display = display }) catch |e| {
        std.debug.print("{t} generation failed ({s}):\n{s}\n", .{ display, @errorName(e), src });
        return e;
    };
    const again = try h.genWith(.{ .display = display });
    try std.testing.expectEqualStrings(o.text, again.text);
    try std.testing.expectEqualStrings(o.prelude, again.prelude);
    try std.testing.expectEqualStrings(o.helpers, again.helpers);
    for ([_][]const u8{ o.text, o.prelude, o.helpers }) |t| for (gen_kernel_text.deprecated_std) |name| {
        if (std.mem.find(u8, t, name)) |at| {
            std.debug.print("{t} device names deprecated `{s}` at byte {d}:\n{s}\n", .{ display, name, at, src });
            return error.TestUnexpectedResult;
        }
    };
    try expectAstGen(o.text);
    try std.testing.expectEqual(o.names.len, o.unit_lo.len);
    try std.testing.expectEqual(o.names.len, o.unit_fn.len);
    try std.testing.expectEqual(o.names.len, o.unit_hi.len);
    for (o.names, o.unit_lo, o.unit_fn, o.unit_hi, 0..) |name, lo, fn_at, hi, i| {
        if (i != 0) try std.testing.expectEqual(o.unit_hi[i - 1], lo);
        try std.testing.expect(lo <= fn_at and fn_at < hi and hi <= o.text.len);
        const decl = try gpa.print("fn {s}(", .{name});
        defer gpa.free(decl);
        try std.testing.expect(std.mem.startsWith(u8, o.text[fn_at..], decl));
        if (display == .emit) continue;
        // `zigbuild.writeTree`'s unit file.
        const file = try std.mem.concat(gpa, u8, &.{ o.prelude, o.text[lo..fn_at], "pub ", o.text[fn_at..hi] });
        defer gpa.free(file);
        try expectAstGen(file);
    }
    if (display != .emit and o.names.len != 0) try expectAstGen(o.helpers);
}

/// One small module per emitter. Each is a source an earlier test in this
/// file (or a fixture) already compiles, so a failure is the structural
/// oracle's and not the source's.
const corpus = [_][]const u8{
    resistor_va,
    shared_va,
    // §5.6.1.2 a reactive split beside a §4.2.12 lazy guard.
    \\module cap(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real c = 1e-12 from (0:inf);
    \\  parameter real vmin = 1.0 from (0:inf);
    \\  analog begin
    \\    I(p, n) <+ c * ddt(V(p, n));
    \\    I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
    \\  end
    \\endmodule
    ,
    // §5.8 structured control flow.
    \\module sw(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real ron = 1.0 from (0:inf);
    \\  parameter real roff = 1e9 from (0:inf);
    \\  analog begin : body
    \\    real g;
    \\    g = 0.0;
    \\    if (V(p, n) > 0.5) g = 1.0 / ron; else g = 1.0 / roff;
    \\    I(p, n) <+ g * V(p, n);
    \\  end
    \\endmodule
    ,
    // §5.6 a potential source, and an inductor's flux.
    \\module vs(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real dc = 1.0;
    \\  analog V(p, n) <+ dc;
    \\endmodule
    ,
    \\module ind(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  analog V(p, n) <+ 1e-9 * ddt(I(p, n));
    \\endmodule
    ,
    // §4.6.4 noise: white and flicker, a guarded source, tables, a shared
    // generator; §4.6.3 a stimulus.
    \\module rnoise(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real rs = 1000.0;
    \\  analog begin
    \\    I(p, n) <+ V(p, n) / rs;
    \\    I(p, n) <+ white_noise(1.6e-23 / rs, "thermal");
    \\    I(p, n) <+ flicker_noise(1e-20, 1.0, "flicker");
    \\  end
    \\endmodule
    ,
    \\module rn(p, n, m);
    \\  inout p, n, m;
    \\  electrical p, n, m;
    \\  parameter real rs = 0.0;
    \\  parameter real ich = 1e-3;
    \\  analog begin
    \\    I(p, n) <+ white_noise(2.0 * 1.602176634e-19 * abs(ich), "shot");
    \\    if (rs > 0.0) begin
    \\      I(n, m) <+ V(n, m) / rs;
    \\      I(n, m) <+ white_noise(1.6e-23 / rs, "rs");
    \\    end else begin
    \\      V(n, m) <+ 0.0;
    \\    end
    \\  end
    \\endmodule
    ,
    \\module ntab(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  analog begin
    \\    I(p, n) <+ noise_table('{1e6, 1e-24, 1.0, 1e-18});
    \\    I(p, n) <+ noise_table_log('{1.0, 1e-18, 1e6, 1e-24});
    \\  end
    \\endmodule
    ,
    \\module nparam(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real tbl[0:3] = '{1e6, 1e-24, 1.0, 1e-18};
    \\  analog I(p, n) <+ noise_table(tbl);
    \\endmodule
    ,
    \\module shared(a, b, c, d);
    \\  inout a, b, c, d;
    \\  electrical a, b, c, d;
    \\  parameter real pwr = 1e-18;
    \\  real nz;
    \\  analog begin
    \\    nz = white_noise(pwr, "shared");
    \\    V(a, b) <+ 2.0 * nz;
    \\    V(d, c) <+ 3.0 * nz;
    \\  end
    \\endmodule
    ,
    \\module stim(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real amp = 2.0;
    \\  real s;
    \\  analog begin
    \\    s = ac_stim("xf", amp, 1.5707963267948966);
    \\    I(p, n) <+ V(p, n) * 1e-3 + 3.0 * s;
    \\    I(p, n) <+ white_noise(1e-18);
    \\  end
    \\endmodule
    ,
    // §5.6.7 indirect contributions.
    \\module amp(out, pin, nin);
    \\  inout out, pin, nin;
    \\  electrical out, pin, nin;
    \\  analog V(out) : V(pin, nin) == 2.0 * V(out);
    \\endmodule
    ,
    \\module two(p, n, c1, c2);
    \\  inout p, n, c1, c2;
    \\  electrical p, n, c1, c2;
    \\  analog begin
    \\    V(p, n) : V(c1) == V(p, n);
    \\    V(p, n) : V(c2) == 2.0 * V(p, n);
    \\  end
    \\endmodule
    ,
    // §4.5 operators: transition and slew, absdelay with and without a
    // maxdelay, idt/idtmod, a nonlinear ddt, both filter families.
    \\module tr(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real td = 1e-9 from (0:inf);
    \\  analog I(p, n) <+ transition(V(p, n), 0.0, td, td) + slew(V(p, n), 2e8);
    \\endmodule
    ,
    \\module dl(p, n);
    \\  inout p, n; electrical p, n;
    \\  analog I(p, n) <+ absdelay(V(p, n), 1e-9) + absdelay(V(p, n), 2n, 3n);
    \\endmodule
    ,
    \\module l(p, n);
    \\  inout p, n; electrical p, n;
    \\  analog I(p, n) <+ idtmod(V(p, n), 0.0, 1.0);
    \\endmodule
    ,
    \\module c(p, n);
    \\  inout p, n; electrical p, n;
    \\  analog I(p, n) <+ V(p, n) * ddt(V(p, n));
    \\endmodule
    ,
    \\module m(a, n);
    \\  inout a, n; electrical a, n;
    \\  analog I(a, n) <+ 1e-3 * idt(1e9, 7.0, V(a, n));
    \\endmodule
    ,
    \\module wmix(p, n, cp, cn);
    \\  inout p, n, cp, cn;
    \\  electrical p, n, cp, cn;
    \\  parameter real num[0:2] = '{1.0, 0.0, 0.0};
    \\  parameter real den[0:2] = '{1.0, 1e-9, 1e-19};
    \\  analog begin
    \\    V(p, n) <+ laplace_nd(V(cp, cn), num, den);
    \\    I(cp, cn) <+ ddt(1e-12 * V(cp, cn));
    \\  end
    \\endmodule
    ,
    \\module zf(p, n);
    \\  inout p, n; electrical p, n;
    \\  analog I(p, n) <+ 1e-3 * zi_nd(V(p, n), '{1.0}, '{1.0}, 2n, 1n);
    \\endmodule
    ,
    // §5.10 events and held state: cross, timer, $prev.
    \\module sw2(p, n, c);
    \\  inout p, n, c; electrical p, n, c;
    \\  integer latched;
    \\  analog begin
    \\    @(cross(V(c) - 0.5, +1)) latched = 1;
    \\    @(cross(V(c) - 0.5, -1)) latched = 0;
    \\    I(p, n) <+ ((latched > 0) ? 1.0 : 1.0e-9) * V(p, n);
    \\  end
    \\endmodule
    ,
    \\module tv(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  integer fired;
    \\  analog begin
    \\    @(timer(V(p, n), 1e-9)) fired = fired + 1;
    \\    I(p, n) <+ fired;
    \\  end
    \\endmodule
    ,
    \\module avg(p, n);
    \\  inout p, n; electrical p, n;
    \\  real g;
    \\  analog begin
    \\    g = 1.0 + 0.1 * V(p, n);
    \\    I(p, n) <+ 0.5 * (g + $prev(g)) * V(p, n);
    \\  end
    \\endmodule
    ,
    // §5.4.3 port probes, §6.5 vector ports, §5.6.5 collapse.
    \\module d(a, c);
    \\  inout a, c;
    \\  electrical a, c;
    \\  parameter real cj = 1e-12;
    \\  real m;
    \\  analog begin
    \\    I(a, c) <+ 1e-3 * V(a, c) + ddt(cj * V(a, c));
    \\    m = I(<a>);
    \\    I(a, c) <+ 1e-9 * m;
    \\  end
    \\endmodule
    ,
    \\module um(p, b);
    \\  inout p;
    \\  inout [0:1] b;
    \\  electrical p, n;
    \\  electrical [0:1] b;
    \\  real x;
    \\  analog begin
    \\    x = I(p, n);
    \\    I(p, n) <+ x + I(<p>);
    \\    I(b[0], b[1]) <+ V(b[0], b[1]);
    \\  end
    \\endmodule
    ,
    \\module dz(a, c);
    \\  inout a, c;
    \\  electrical a, c, ai;
    \\  parameter real rs = 0.0 from [0:inf);
    \\  branch (a, ai) rsb;
    \\  analog begin
    \\    I(ai, c) <+ 1e-3 * V(ai, c);
    \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
    \\    else          V(rsb) <+ 0.0;
    \\  end
    \\endmodule
    ,
    // §5.9 a loop, §3.2.2 a memory-backed array, a §4.2.7 short circuit.
    \\module lp(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  integer i;
    \\  real a, b;
    \\  analog begin
    \\    a = 0.0;
    \\    b = 0.0;
    \\    for (i = 1; i <= 5; i = i + 1) begin
    \\      a = a + i;
    \\      b = b + i * 2;
    \\    end
    \\    I(p, n) <+ a * V(p, n);
    \\    I(p) <+ b * V(p);
    \\  end
    \\endmodule
    ,
    \\module arr(p, n);
    \\  inout p, n; electrical p, n;
    \\  integer sp;
    \\  real st[0:31];
    \\  analog begin
    \\    sp = ($abstime < 0.5) ? 1 : 2;
    \\    st[sp] = V(p, n);
    \\    I(p, n) <+ st[sp] + st[sp - 1];
    \\  end
    \\endmodule
    ,
    \\module wl(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  analog begin : body
    \\    real x, y; integer i;
    \\    x = 1e6; y = V(p, n); i = 0;
    \\    while ((i <= 4) && (abs(y - x) > 1e-12)) begin
    \\      x = y;
    \\      y = 2.0 * y + 1.0;
    \\      i = i + 1;
    \\    end
    \\    I(p, n) <+ y;
    \\  end
    \\endmodule
    ,
    // §3.2 integers at 32 bits; §4.6.1 analysis and time.
    \\module w(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter integer big = 2147483647 + 1;
    \\  parameter integer chained = big + 1;
    \\  localparam integer sh = 1 << 31;
    \\  analog begin
    \\    I(p, n) <+ V(p, n) * (big + 1);
    \\  end
    \\endmodule
    ,
    \\module ak(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  analog I(p, n) <+ V(p, n) * (analysis("tran") ? 2.0 : 1.0) + 1e-3 * V(p, n) * $abstime;
    \\endmodule
    ,
    // §4.5.15 a signed `$limit`.
    \\module lim(p);
    \\  inout p; electrical p; electrical mid;
    \\  parameter real vt = 0.025852;
    \\  parameter real vc = 0.6;
    \\  parameter real type = -1.0;
    \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc, type) - V(p)) / 1.0;
    \\endmodule
    ,
    // §9.4/§9.7.3 display tasks, one under a branch; §9.5 a descriptor.
    \\module disp(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real g = 2.0;
    \\  analog begin
    \\    $strobe("g=%g n=%5d s=%s", g, 42, "x");
    \\    $write("no newline");
    \\    if (V(p, n) > 0.5) $strobe("hi");
    \\    $warning("careful");
    \\    I(p, n) <+ g * V(p, n);
    \\  end
    \\endmodule
    ,
    \\module fdev(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  integer fd;
    \\  analog begin
    \\    fd = $fopen("nope.txt");
    \\    I(p, n) <+ V(p, n) * (fd + 1);
    \\  end
    \\endmodule
    ,
};

test "codegen: every corpus device is valid Zig, deterministic and tiled, in every display mode" {
    for (corpus) |src| {
        try expectSoundDevice(src, .drop);
        try expectSoundDevice(src, .emit);
        try expectSoundDevice(src, .record);
    }
}

test "codegen: §4.5.8 a lone rise_time sets the fall time over `default_transition" {
    // §4.5.8: "If only a positive rise_time value is specified, the simulator
    // uses it for both rise and fall times. If neither rise_time nor
    // fall_time are specified or are equal to zero (0.0), the rise and fall
    // time default to the value defined by `default_transition." §10.3 scopes
    // the directive to the filters that "do not have rise time and fall time
    // arguments specified".
    //
    // So under `default_transition 8n, transition(x, 0, 4n) rises AND falls
    // in 4n. The residual kernel and the accepted-step bookkeeping both get 4n
    // twice, and the directive's 8n reaches neither (`fmtF64` spells 4e-9 as
    // 0.000000004 and 8e-9 as 0.000000008).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\`default_transition 8n
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0, 4n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src, "sim.t, sim.dt, 0.000000004, 0.000000004)") != null);
    try std.testing.expect(std.mem.find(u8, src, ", 0.000000004, 0.000000004);\n") != null);
    try std.testing.expect(std.mem.find(u8, src, "0.000000008") == null);

    // With neither time given, the directive is both.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\`default_transition 8n
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n));
        \\endmodule
    , &h2);
    defer h2.deinit();
    const src2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, src2, "sim.t, sim.dt, 0.000000008, 0.000000008)") != null);
}

test "codegen: §4.2.4 an integer `/` by -1 cannot trap; any other literal stays bare" {
    // `/` by -1 is negation, and negating minInt overflows: a bare
    // `@divTrunc(a, -1)` panics in a safe build and traps (SIGFPE) in a
    // ReleaseFast one at a = minInt(i64), which a saturated §4.2.1.1
    // conversion (`zRoundI`) or a card-written integer parameter holds. The
    // host's spelling of the same division (`i64Const`, which `derive` runs)
    // divides in i65 and wraps; the device must give that answer, not a trap.
    // A divisor that is neither 0 nor -1 cannot overflow and keeps the bare
    // `@divTrunc`.
    const cases = [_]struct { expr: []const u8, bare: bool }{
        .{ .expr = "k / -1", .bare = false },
        .{ .expr = "k / 3", .bare = true },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  integer k, j;
            \\  analog begin
            \\    k = V(p, n) * 1e3;
            \\    j = {s};
            \\    I(p, n) <+ j * V(p, n);
            \\  end
            \\endmodule
        , .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);
        // The bare form truncates the quotient straight to §3.2's 32 bits.
        try std.testing.expectEqual(c.bare, std.mem.find(u8, out, "@as(i32, @truncate(@divTrunc(") != null);
        if (!c.bare) try std.testing.expect(std.mem.find(u8, out, "@divTrunc(@as(i65, zd_a), zd_b)") != null);
    }
}

test "codegen: a setup of flags alone discards its scalar, a quoted \"S\" notwithstanding" {
    // `setup` keeps `const S = V;` only for a body that names `S`, since an
    // unused local is a Zig error. A §3.4.6 string comparison puts the
    // LITERAL "S" in a body that is otherwise flags, and a literal is not a
    // use of the identifier: the device must still be Zig.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sf(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter string mode = "S";
        \\  analog begin
        \\    if (mode == "S") I(p, n) <+ V(p, n);
        \\    else I(p, n) <+ 2.0 * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try expectAstGen(try h.gen(std.testing.allocator));
}

test "codegen: §6.5.2.2 `U` is enum(u8) to 256 unknowns and as wide as the count past them" {
    // #29: 256 unknowns was a ceiling (E1003) below §6.5.2.2's "shall
    // support a minimum of 256 ports". A vector port of n elements and one
    // internal net is n + 1 unknowns.
    const gpa = std.testing.allocator;
    for ([_]struct { n: u32, tag: []const u8 }{
        .{ .n = 255, .tag = "pub const U = enum(u8) {" },
        .{ .n = 256, .tag = "pub const U = enum(u9) {" },
        .{ .n = 600, .tag = "pub const U = enum(u10) {" },
        .{ .n = 70000, .tag = "pub const U = enum(u17) {" },
    }) |c| {
        const src = try gpa.print(
            \\module big(b);
            \\  inout [0:{d}] b;
            \\  electrical [0:{d}] b;
            \\  electrical m;
            \\  analog I(b[{d}], m) <+ V(b[{d}], m);
            \\endmodule
            \\
        , .{ c.n - 1, c.n - 1, c.n - 1, c.n - 1 });
        defer gpa.free(src);
        var h: Harness = undefined;
        try Harness.run(gpa, src, &h);
        defer h.deinit();
        const out = try h.genWith(.{});
        try std.testing.expect(std.mem.find(u8, out.text, c.tag) != null);
    }
}

test "codegen: a $limit on an unknown past 63 names exactly its unknowns in u72 live sets" {
    // `limit_reads`/`limit_writes` are `contract.MaskOf(|U|)` masks, so past
    // 64 unknowns each unknown still has its own bit. The junction is
    // V(a69, n): a69 is unknown 2 + 69 = 71 (ports first) and n unknown 1;
    // the clamp reads both and writes a69.
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module big(p, n);\n  inout p, n;\n  electrical p, n;\n  electrical ");
    for (0..70) |i| try src.print(gpa, "{s}a{d}", .{ if (i == 0) "" else ", ", i });
    try src.appendSlice(gpa, ";\n  analog begin\n    I(p, a0) <+ V(p, a0);\n");
    for (1..70) |i| try src.print(gpa, "    I(a{d}, a{d}) <+ V(a{d}, a{d});\n", .{ i - 1, i, i - 1, i });
    try src.appendSlice(gpa, "    I(a69, n) <+ 1e-14 * (exp($limit(V(a69, n), \"pnjlim\", 0.025, 0.6) / 0.025) - 1.0);\n  end\nendmodule\n");
    var h: Harness = undefined;
    try Harness.run(gpa, src.items, &h);
    defer h.deinit();
    const out = try h.genWith(.{});
    try std.testing.expect(std.mem.find(u8, out.text, "pub const limit_reads: u72 = 0x800000000000000002;") != null);
    try std.testing.expect(std.mem.find(u8, out.text, "pub const limit_writes: u72 = 0x800000000000000000;") != null);
}

test "codegen: §4.5.7 `delays` reports the delay maxdelay leaves" {
    // §4.5.7: "If td becomes greater than maxdelay, maxdelay will be used as
    // a substitute for td." The residual already runs `@min(td, maxdelay)`
    // (`absdelayTd`); the breakpoint table the host lands its echoes from
    // must carry the same delay, or each echo lands td after a corner the
    // device delayed by maxdelay. A two-argument site has no substitute.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dl(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ absdelay(V(p, n), 2n, 1n) + absdelay(V(p, n), 3n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.find(u8, src, "pub fn delays(").?;
    const body = src[at..std.mem.findPos(u8, src, at, "\n}\n").?];
    try std.testing.expect(std.mem.find(u8, body, "@min(0.000000002, 0.000000001)") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "@min("));
    try std.testing.expect(std.mem.find(u8, body, "0.000000003") != null);
}

test "codegen: §9.4.3 a recorded `%l` is the printing artifact's library.cell" {
    // Table 9-22's `%l` is "library.cell", which `translateFormat` writes as
    // `work.<module>` (IEEE 1364-2005 §13.2.1's default library). A `.record`
    // device fixes the same site's text in `say_sites`, and the host must
    // render what the printing artifact prints.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module t(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    $strobe("in %l");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const rec = try h.genWith(.{ .display = .record });
    try std.testing.expect(std.mem.find(u8, rec.text, ".fmt = \"in work.t\\n\"") != null);
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, exe, "\"in work.t\\n\"") != null);
}

test "codegen: fmtF64 writes every float literal as a Zig float" {
    // `{d}` gives the shortest round-trip decimal and no point for an
    // integral value; the `.0` keeps an integral real a float where Zig
    // infers (`S.con(3.0)`), and a huge or tiny value stays decimal.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module f(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real a = 1e21;
        \\  parameter real b = 1e-7;
        \\  parameter real c = 2.5;
        \\  parameter real d = 3;
        \\  analog I(p, n) <+ V(p, n) * (a + b + c + d);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    for ([_][]const u8{
        "    a: f64 = 1000000000000000000000.0,\n",
        "    b: f64 = 0.0000001,\n",
        "    c: f64 = 2.5,\n",
        "    d: f64 = 3.0,\n",
    }) |want| if (std.mem.find(u8, src, want) == null) {
        std.debug.print("missing `{s}`\n", .{want});
        return error.TestUnexpectedResult;
    };
}

test "codegen: limit_reads is every lane for a core re-entry and the clamp's unknowns otherwise" {
    const gpa = std.testing.allocator;
    // §9.17.1 `$discontinuity(-1)` under a core-computed condition: `limit`
    // re-enters the core, which is seeded from every entry of `old`.
    var core: Harness = undefined;
    try Harness.run(gpa,
        \\module dc(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    if (V(p,n) >= 0.0) $discontinuity(0);
        \\    else $discontinuity(-1);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &core);
    defer core.deinit();
    const a = try core.genWith(.{});
    try std.testing.expect(std.mem.find(u8, a.text, "pub const limit_reads: u64 = 0xffffffffffffffff;") != null);
    // A clamp on literal arguments reads only its own junction, a (2) and
    // n (1), and writes a, the internal net.
    var lit: Harness = undefined;
    try Harness.run(gpa,
        \\module d(p, n);
        \\  inout p, n; electrical p, n, a;
        \\  analog begin
        \\    I(p, a) <+ V(p, a);
        \\    I(a, n) <+ 1e-14 * (exp($limit(V(a, n), "pnjlim", 0.025, 0.6) / 0.025) - 1.0);
        \\  end
        \\endmodule
    , &lit);
    defer lit.deinit();
    const b = try lit.genWith(.{});
    try std.testing.expect(std.mem.find(u8, b.text, "pub const limit_reads: u64 = 0x6;") != null);
    try std.testing.expect(std.mem.find(u8, b.text, "pub const limit_writes: u64 = 0x4;") != null);
}

test "codegen: a lane-free version of an x-dependent array is read through zStrip" {
    // The storage is typed by the union of its versions (0x1, a later store
    // of V(p)); a read of the version holding only constants has no lanes,
    // so it is stripped rather than narrowed by a `zTo` that refuses (#89).
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    try Harness.run(gpa,
        \\module md(p, n);
        \\  inout p, n; electrical p, n;
        \\  (* vera_scratch *) real st[0:2];
        \\  real y;
        \\  integer k;
        \\  analog begin
        \\    k = ($abstime < 0.5) ? 1 : 2;
        \\    st[k] = 3.0;
        \\    y = st[k];
        \\    st[k] = V(p);
        \\    I(p, n) <+ y * V(p, n) + st[k];
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(gpa);
    try std.testing.expect(std.mem.find(u8, src, "zStrip(S, zArrLd(") != null);
}

test "codegen: a long constant sum is one literal, with no unread `tN` local" {
    // Every partial sum folds (`UnitPlan.literal`), so none is hoisted into a
    // local its folded user would leave unread: Zig rejects an unused local.
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module ls(p, n);\n  inout p, n; electrical p, n;\n  real r;\n  analog begin\n    r = 1.0");
    for (0..1000) |_| try src.appendSlice(gpa, " + 1.0");
    try src.appendSlice(gpa, ";\n    $strobe(\"%g\", r);\n    I(p, n) <+ r * V(p, n);\n  end\nendmodule\n");
    var h: Harness = undefined;
    try Harness.run(gpa, src.items, &h);
    defer h.deinit();
    const out = try h.genDisplay(h.arena_state.allocator());
    try std.testing.expect(std.mem.find(u8, out, "S.con(1001.0)") != null);
    try std.testing.expect(std.mem.find(u8, out, "const t0 = S.con(2.0)") == null);
    try std.testing.expect(std.mem.find(u8, out, "= S.con(258.0)") == null);
}

test "codegen: a display of a constant branch flow reads the core cache it declares" {
    // `I(p, n)` is the contribution's value, a folded literal the core
    // returns; the display unit reads it as `c.f0`, so it must declare `c`.
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    try Harness.run(gpa,
        \\module cs(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ 1.0e-3;
        \\    $strobe("%g", I(p, n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const out = try h.genDisplay(h.arena_state.allocator());
    const at = std.mem.find(u8, out, "__display__tasks(comptime").?;
    const body = out[at..];
    const read = std.mem.find(u8, body, "c.f0").?;
    const decl = std.mem.find(u8, body, "const c = ").?;
    try std.testing.expect(decl < read);
}

test "codegen: a folded want whose operands the core returns reads no undeclared `c`" {
    // `--perturb`'s CHECK (`check.vh` VERA_PW): the want folds to one number
    // (`UnitPlan.literal`), so the display unit plans none of its operands,
    // even the ones the core returns. Every spelling of it, `f64Const`
    // included, must then be the number, never `c.f<k>` (#perturb).
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    try Harness.run(gpa,
        \\module mt(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer k;
        \\  analog begin
        \\    @(timer(1e-3, 1e-3)) k = 0;
        \\    @(timer(2e-3, 2e-3)) k = 1;
        \\    $strobe("%g ok=%d", (0.75) * (1 + (1e-3)) + ((0.75) == 0) * (1e-3),
        \\            (abs((V(p, n)) - ((0.75) * (1 + (1e-3)) + ((0.75) == 0) * (1e-3))) <= (1e-12)));
        \\    I(p, n) <+ 1e-3 * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const out = try h.genDisplay(h.arena_state.allocator());
    const at = std.mem.find(u8, out, "__display__tasks(comptime").?;
    const end = std.mem.findPos(u8, out, at, "\n}\n").?;
    const body = out[at..end];
    if (std.mem.find(u8, body, "c.f") != null) try std.testing.expect(std.mem.find(u8, body, "const c = ") != null);
}

test "generate: a chain of 5000 fused statements generates on a 1 MiB stack" {
    // Length, not nesting: each statement reads the last one's value once,
    // so the planner fuses them into one expression up to
    // `max_inline_depth` deep, which no parse depth sizes the caller's
    // stack for. The renderer took four frames (about 8 KiB in Debug) per
    // fused operand and overflowed 1 MiB (pass-3 oracles' `wide`
    // generator, `chain.va`). Two shapes: a `+` chain (`renderArith`'s
    // loop) and `sin` between the sums (`renderInst`'s segments).
    // Oracle: §4.3 arithmetic over literals; the text names every
    // statement's constant, the last one's included.
    const gpa = std.testing.allocator;
    const n = 5000;
    for ([_][]const u8{ "y + {d}.5", "sin(y) + {d}.5" }) |form| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module m(p, n);\n  inout p, n;\n  electrical p, n;\n  real y;\n  analog begin\n    y = V(p, n);\n");
        for (0..n) |i| {
            try src.appendSlice(gpa, "    y = ");
            try src.print(gpa, "{s}", .{form[0..std.mem.find(u8, form, "{d}").?]});
            try src.print(gpa, "{d}.5;\n", .{i});
        }
        try src.appendSlice(gpa, "    I(p, n) <+ y;\n  end\nendmodule\n");
        const Run = struct {
            h: Harness = undefined,
            lowered: anyerror!void = {},
            out: anyerror!Output = error.NotRun,
            fn lower(r: *@This(), text: []const u8) void {
                r.lowered = Harness.run(std.testing.allocator, text, &r.h);
            }
            fn gen(r: *@This()) void {
                r.out = r.h.genWith(.{});
            }
        };
        var r: Run = .{};
        const t0 = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, Run.lower, .{ &r, src.items });
        t0.join();
        defer r.h.deinit();
        try r.lowered;
        const t1 = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Run.gen, .{&r});
        t1.join();
        const out = try r.out;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            var buf: [16]u8 = undefined;
            const lit = try std.fmt.bufPrint(&buf, "{d}.5", .{k});
            std.testing.expect(std.mem.find(u8, out.text, lit) != null) catch |e| {
                std.debug.print("form `{s}`: no `{s}` in the text\n", .{ form, lit });
                return e;
            };
        }
    }
}

test "generate: a held string built by 20000 concatenations generates on a 1 MiB stack" {
    // Length, not nesting: one statement per concatenation, so no parse depth
    // sizes the caller's stack. Sizing the held string's row (`cg_strcap`)
    // walked the chain one call per piece before any site was emitted and
    // overflowed it (`vera --emit-zig` segfaulted at 20000). Oracle: §3.3
    // Table 3-3 gives each `{s, sp}` the sum of its operands' lengths, and
    // `sp` is a parameter a card may set, so every piece counts
    // `cg_strcap.row` (4096 bytes) and the row the device declares is 20000
    // of them.
    const gpa = std.testing.allocator;
    const pieces = 20000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p);\n  inout p;\n  electrical p;\n  string s;\n  parameter string sp = \"x\";\n  analog begin\n    @(initial_step) begin\n      s = \"\";\n");
    for (0..pieces) |_| try src.appendSlice(gpa, "      s = {s, sp};\n");
    try src.appendSlice(gpa, "    end\n    I(p) <+ V(p);\n  end\nendmodule\n");
    const Run = struct {
        h: Harness = undefined,
        lowered: anyerror!void = {},
        out: anyerror!Output = error.NotRun,
        fn lower(r: *@This(), text: []const u8) void {
            r.lowered = Harness.run(std.testing.allocator, text, &r.h);
        }
        fn gen(r: *@This()) void {
            r.out = r.h.genWith(.{ .display = .emit });
        }
    };
    var r: Run = .{};
    const t0 = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, Run.lower, .{ &r, src.items });
    t0.join();
    defer r.h.deinit();
    try r.lowered;
    const t1 = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Run.gen, .{&r});
    t1.join();
    const out = try r.out;
    const want = try gpa.print("ZStrHeldN({d})", .{pieces * 4096});
    defer gpa.free(want);
    try std.testing.expect(std.mem.find(u8, out.text, want) != null);
}

test "generate: degenerate legal devices generate, or refuse with a code, never trip an assert" {
    // The class behind five integration bugs: an assertion on a shape a legal
    // source can take (a ground terminal, no unknowns, a one-point table, an
    // empty argument). Oracle: the LRM says each source below is legal, or
    // names the rule it breaks (the code listed); a Debug build turns any
    // assert on it into a crash. Every display mode, since each renders its
    // own units. Name list: each row's first error code, compared exactly.
    const Case = struct { body: []const u8, err: ?diag.Code = null };
    const cases = [_]Case{
        .{ .body = "" }, // no port, no analog block
        .{ .body = "analog begin end" },
        .{ .body = "analog $display(\"x\");" }, // no unknowns at all
        .{ .body = "analog $strobe;" },
        .{ .body = "electrical a; analog I(p) <+ 0;" }, // an unused internal node
        .{ .body = "ground g; electrical g; analog I(p, g) <+ V(p, g);" }, // a ground terminal
        .{ .body = "real a[0:0]; analog begin a[0] = V(p); I(p) <+ a[0]; end" }, // a 1-element array
        .{ .body = "integer k; real y; analog begin k = V(p); y = 0; case (k) 0: y = 1.0; endcase I(p) <+ y; end" },
        .{ .body = "integer i; real y; analog begin y = 0; for (i = 0; i < 0; i = i + 1) y = y + V(p); I(p) <+ y; end" },
        .{ .body = "real x; analog begin @(initial_step) x = 1.0; I(p) <+ x; end" }, // held state only
        .{ .body = "parameter string s = \"\"; analog begin $display(\"%s\", s); I(p) <+ V(p); end" },
        .{ .body = "analog I(p) <+ ddt(1.0);" },
        .{ .body = "analog I(p) <+ V(p) + noise_table({1.0, 2.0});" }, // a one-point table
        .{ .body = "analog I(p) <+ V(p) + white_noise(0.0);" },
        .{ .body = "analog I(p) <+ ac_stim();" },
        // A.8.2 `ac_stim` has three slots.
        .{ .body = "analog I(p) <+ ac_stim(\"ac\", 1, 0, 5);", .err = .E0506 },
        // §5.4.2 a branch needs two distinct nets.
        .{ .body = "analog V(p, p) <+ 0;", .err = .E0315 },
    };
    const gpa = std.testing.allocator;
    for (cases) |cs| for ([_]codegen.Display{ .drop, .record, .emit }) |display| {
        const src = try gpa.print("`include \"disciplines.vams\"\nmodule m(p);\n  inout p;\n  electrical p;\n  {s}\nendmodule\n", .{cs.body});
        defer gpa.free(src);
        var h: Harness = undefined;
        const lowered = Harness.run(gpa, src, &h);
        defer h.deinit();
        // A refusal at lowering leaves its code in `first_error`.
        if (lowered) |_| {} else |e| if (e != error.DiagnosticsReported) return e;
        const a = h.arena_state.allocator();
        const ran = if (lowered) |_| true else |_| false;
        if (ran and !h.bag.failed()) {
            // As `Compilation.lowerAndProve` runs it.
            _ = try ifconv.run(a, &h.mir, .pure, null);
            const v = try proof.prove(a, &h.mir, &h.lowered, .{}, &h.bag);
            _ = try ifconv.run(a, &h.mir, .speculate, null);
            if (!h.bag.failed()) _ = try generate(a, a, &h.mir, &h.lowered, v, .{ .display = display, .diags = &h.bag });
        }
        var first: ?diag.Code = h.first_error;
        for (0..h.bag.count()) |i| if (h.bag.at(i).severity == .err) {
            first = h.bag.at(i).code;
            break;
        };
        std.testing.expectEqual(cs.err, first) catch |e| {
            std.debug.print("case `{s}` (display {t})\n", .{ cs.body, display });
            return e;
        };
    };
}
