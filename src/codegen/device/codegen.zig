//! Mir + Lowered + proof.Verdict -> device.zig: one Zig function per source
//! unit, then the `eval`/`q` dispatchers, the §4.5.2 state machine and the
//! decls `contract.validate` checks. Each unit has a stable name
//! (`ir/names.zig`) and a uniform signature, so `zig -fincremental`
//! re-analyses only what changed. Identical MIR gives byte-identical output.
//! `prepare.zig` plans the device, `file.emitFile` (the spine) writes it.
//! Cites: §5, §4.5, Clause 9, §8.3.
//!
//! Contents:
//! - `pub const Output = @import("zigbuild").Output`
//! - `pub const Gen = @import("Gen.zig")`
//! - `pub const Error`
//! - `pub const none_u32: u32 = std.math.maxInt(u32)`
//! - `pub const Display = plan_args.Display`
//! - `pub const VTy = Analysis.VTy`
//! - `pub const Options = struct`
//! - `pub const Device = struct`
//! - `pub fn generate(gpa: Allocator, arena: Allocator, mir: *const Mir, lowered: *const Lowered, verdict: proof.Verdict, opts: Options) Error!Device`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Analysis = @import("prove").Analysis;
const proof = @import("prove").proof;
const diag = @import("diag");
const plan_args = @import("codegen/plan/args.zig");
const prepare = @import("prepare.zig");

/// The generated device and its per-unit ranges: the value `zigbuild` writes
/// and builds, defined there (`zigbuild.Output`) so the build never imports
/// codegen. `generate` produces it.
pub const Output = @import("zigbuild").Output;

/// The emitter's state; see `Gen.zig`.
pub const Gen = @import("Gen.zig");

/// Every way `generate` fails. Out of memory aside, each is a refusal of the
/// whole device: no partial `Output` is returned and nothing the caller
/// passed is changed. A refusal confined to one unit is not an error here but
/// a `@compileError` body plus `Device.compile_error`.
pub const Error = Allocator.Error || error{
    /// proof.zig rejected the model. `generate` returns this before emitting
    /// a byte.
    DomainErrors,
    /// A numeric parameter default cannot follow host-written dependencies.
    UnsupportedParameterDefault,
};

/// Sentinel for "no index" in the u32 columns (`Hoist.idx`, a non-held array).
pub const none_u32: u32 = std.math.maxInt(u32);

/// §9.4: whether display tasks are dropped, recorded or emitted (plan/args.zig).
pub const Display = plan_args.Display;

/// The value-type lattice lives with the analysis that computes it.
pub const VTy = Analysis.VTy;

/// Settings that change what is generated.
pub const Options = struct {
    /// §9.4: `.emit` builds the testbench's `display` unit; `.record` a solver
    /// device whose `say` records its display tasks for the host; `.drop` a
    /// solver device without one.
    display: Display = .drop,
    /// Emits `pub const jac_f32 = true`: the host may carry the derivative half
    /// of S in single precision. Changes no emitted arithmetic, since every
    /// primitive takes and returns f64 at the boundary. The device states it
    /// because only the physics knows whether its unknowns fit in f32's ~7
    /// digits. A permission, not an order: a host may take it on one
    /// instantiation and decline it on another.
    jac_f32: bool = false,
    /// Also emits `pub const jac_f32_host = true`: the host should take the
    /// permission on its CPU instantiation too. Implies `jac_f32`;
    /// `lib/contract.zig` rejects it without the permission.
    jac_f32_host: bool = false,
    /// Where a codegen-stage diagnostic (E0515) goes. With none, a refusal is
    /// reported through `Device.compile_error` alone. This is the caller's
    /// bag, alive as long as the `CompileResult`; `lower.bag` is not, because
    /// `root.finish` has already detached it by the time codegen runs.
    diags: ?*diag.Bag = null,
    /// Emits `vpiContribs` and its row tables: both halves of every §5.6
    /// contribution by `Lowered.contributions` index, for a host answering
    /// §12.10 `vpi_get_analog_value` on a branch flow; and, when instances
    /// share a row, `vpiShares` and `vpi_share_row`: each one's own share
    /// (`Lowered.contrib_shares`).
    vpi_contribs: bool = false,
};

/// What `generate` returns: the device and whether any part of it was refused.
pub const Device = struct {
    /// The text and its unit ranges (see `generate` for ownership).
    output: Output,
    /// Set for any refusal: a unit collapsed to `@compileError`, a refused
    /// export outside the units, or a diagnostic in `Options.diags` that
    /// failed the compilation. The text still builds up to that error.
    compile_error: bool,
};

/// Emits the whole device.zig (LRM §5, §8.3).
///
/// `arena` must be the per-compilation arena: every scratch table lives on it
/// and this pass has no deinit. `gpa` owns `Device.output.text` and nothing
/// else; the caller frees it with `gpa`. The other `Output` slices are
/// arena-owned. The text is on the gpa because it grows without bound and an
/// arena regrows anything but its latest allocation by copying.
/// Returns `error.DomainErrors` without emitting when `verdict` rejects the
/// model. Deterministic: nothing on this path iterates a hash map.
/// Recurses as deep as the source nests expressions: run it on a stack sized
/// for that (`deep_stack.run`).
pub fn generate(
    gpa: Allocator,
    arena: Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    verdict: proof.Verdict,
    opts: Options,
) Error!Device {
    if (!verdict.ok()) return error.DomainErrors;
    // §6.2: the port list is optional, so a module with no ports or nets is
    // valid. It yields a device with `num_ports == 0` and an empty `U`.
    const an = try Analysis.build(arena, mir, lowered);
    var g: Gen = .{
        .gpa = gpa,
        .an = &an,
        .arena = arena,
        .mir = mir,
        .lowered = lowered,
        .verdict = verdict,
        .display = opts.display,
        .float = .{ .jac = .of(opts.jac_f32, opts.jac_f32_host) },
        .diags = opts.diags,
        .vpi_contribs = opts.vpi_contribs,
    };
    errdefer g.out.deinit(gpa);
    try prepare.prepare(&g);
    try g.emitFile();
    assert(g.out.items.len != 0);
    const files = g.files.slice();
    assert(files.items(.lo).len == files.items(.hi).len);
    // Every unit row was closed: its declaration starts inside its range.
    for (files.items(.lo), files.items(.fn_at), files.items(.hi)) |lo, at, hi| {
        assert(lo <= at);
        assert(at <= hi);
    }
    return .{
        .compile_error = g.any_fatal or (if (opts.diags) |bag| bag.failed() else false),
        .output = .{
            .text = try g.out.toOwnedSlice(gpa),
            .names = files.items(.name),
            .unit_lo = files.items(.lo),
            .unit_fn = files.items(.fn_at),
            .unit_hi = files.items(.hi),
            .prelude = g.prelude,
            .helpers = g.helpers,
            .setup_chunks = g.su.chunks,
        },
    };
}

// ---- private ----

test {
    _ = Gen;
    _ = prepare;
    _ = @import("codegen/plan/names.zig");
    _ = @import("codegen/plan/topology.zig");
    _ = @import("codegen/plan/limit.zig");
    _ = @import("codegen/plan/noise.zig");
    _ = @import("codegen/plan/jobs.zig");
    _ = @import("codegen/plan/core.zig");
    _ = plan_args;
    _ = @import("codegen/plan/qsite.zig");
    _ = @import("codegen/plan/jac.zig");
    _ = @import("codegen/plan/unit.zig");
    _ = @import("codegen/float/mode.zig");
    _ = @import("codegen/float/lanes.zig");
    _ = @import("codegen/setup.zig");
    _ = @import("codegen/setup_chunk.zig");
    _ = @import("codegen/file.zig");
    _ = @import("codegen/instance.zig");
    _ = @import("codegen/unit.zig");
    _ = @import("codegen/cfg.zig");
    _ = @import("codegen/render.zig");
    _ = @import("codegen/host_expr.zig");
    _ = @import("codegen/call.zig");
    _ = @import("codegen/dispatch.zig");
    _ = @import("codegen/noise.zig");
    _ = @import("codegen/state.zig");
    _ = @import("codegen/kernel_text.zig");
    _ = @import("codegen/opcode_zig.zig");
}

test "generate: a case of 2500 arms generates on a 1 MiB stack" {
    // Width, not nesting: lowering turns the arms into a chain as long as
    // the case is wide, which no parse nesting measures, so the caller's
    // stack (`deep_stack.run` sized from source nesting) is the default one.
    // Codegen walked that chain one call per arm and overflowed it (#105,
    // case_5000). Oracle: generation succeeds with no refusal, and the
    // device's text names the last arm's value.
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p, n);\n  inout p, n;\n  electrical p, n;\n  real y;\n  integer k;\n  analog begin\n    k = V(p, n);\n    case (k)\n");
    // 2500 arms already overflowed 1 MiB, in a fraction of 5000 arms' time.
    const arms = 2500;
    for (0..arms) |i| try src.print(gpa, "      {d}: y = {d}.0;\n", .{ i, i });
    try src.appendSlice(gpa, "    endcase\n    I(p, n) <+ y;\n  end\nendmodule\n");

    const Run = struct {
        h: @import("codegen/harness.zig").Harness = undefined,
        lowered: anyerror!void = {},
        out: anyerror!Output = error.NotRun,
        fn lower(r: *@This(), text: []const u8) void {
            r.lowered = @import("codegen/harness.zig").Harness.run(std.testing.allocator, text, &r.h);
            // As `Compilation.lowerAndProve` does: the case's diamonds become
            // one chain of selects as long as the case is wide.
            if (r.lowered) |_| {
                const ifconv = @import("prove").ifconv;
                const a = r.h.arena_state.allocator();
                _ = ifconv.run(a, &r.h.mir, .pure, null) catch |e| {
                    r.lowered = e;
                };
                // A `.strict` unit keeps nothing as CFG: every arm speculates.
                _ = ifconv.run(a, &r.h.mir, .speculate, null) catch |e| {
                    r.lowered = e;
                };
            } else |_| {}
        }
        fn gen(r: *@This()) void {
            r.out = r.h.genWith(.{});
        }
    };
    var r: Run = .{};
    // Lowering has its own stack budget (analog's test); give it room.
    const t0 = try std.Thread.spawn(.{ .stack_size = 256 << 20 }, Run.lower, .{ &r, src.items });
    t0.join();
    try r.lowered;
    defer r.h.deinit();
    const t1 = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Run.gen, .{&r});
    t1.join();
    // The harness generates into its own arena, freed by `deinit`.
    const out = try r.out;
    try std.testing.expect(std.mem.countScalar(Mir.Opcode, r.h.mir.insts.items(.op), .select) >= arms - 1);
    try std.testing.expect(std.mem.find(u8, out.text, "2499.0") != null);
}

test "generate: a held string built by 20000 concatenations generates on a 1 MiB stack" {
    // Length, not nesting: one statement per concatenation, so no parse depth
    // sizes the caller's stack. Sizing the held string's row (`cg_strcap`)
    // walked the chain one call per piece before any site was emitted and
    // overflowed it (8 MiB at 20000 pieces). Oracle: §3.3 Table 3-3 gives
    // each `{s, sp}` the sum of its operands' lengths, and `sp` is a
    // parameter a card may set, so every piece counts `cg_strcap.row` and the
    // row the device declares is 20000 of them.
    const gpa = std.testing.allocator;
    const pieces = 20000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p);\n  inout p;\n  electrical p;\n  string s;\n  parameter string sp = \"x\";\n  analog begin\n    @(initial_step) begin\n      s = \"\";\n");
    for (0..pieces) |_| try src.appendSlice(gpa, "      s = {s, sp};\n");
    try src.appendSlice(gpa, "    end\n    I(p) <+ V(p);\n  end\nendmodule\n");
    const Run = struct {
        h: @import("codegen/harness.zig").Harness = undefined,
        lowered: anyerror!void = {},
        out: anyerror!Output = error.NotRun,
        fn lower(r: *@This(), text: []const u8) void {
            r.lowered = @import("codegen/harness.zig").Harness.run(std.testing.allocator, text, &r.h);
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
    const want = try gpa.print("ZStrHeldN({d})", .{pieces * @import("cg_strcap.zig").row});
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
    for (cases) |cs| for ([_]Display{ .drop, .record, .emit }) |display| {
        const src = try gpa.print("`include \"disciplines.vams\"\nmodule m(p);\n  inout p;\n  electrical p;\n  {s}\nendmodule\n", .{cs.body});
        defer gpa.free(src);
        var h: @import("codegen/harness.zig").Harness = undefined;
        const lowered = @import("codegen/harness.zig").Harness.run(gpa, src, &h);
        defer h.deinit();
        // A refusal at lowering lands in the bag.
        if (lowered) |_| {} else |e| if (e != error.DiagnosticsReported) return e;
        const a = h.arena_state.allocator();
        if (!h.bag.failed()) {
            // As `Compilation.lowerAndProve` runs it.
            const ifconv = @import("prove").ifconv;
            _ = try ifconv.run(a, &h.mir, .pure, null);
            const v = try proof.prove(a, &h.mir, &h.lowered, .{}, &h.bag);
            _ = try ifconv.run(a, &h.mir, .speculate, null);
            if (!h.bag.failed()) _ = try generate(a, a, &h.mir, &h.lowered, v, .{ .display = display, .diags = &h.bag });
        }
        var first: ?diag.Code = null;
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
