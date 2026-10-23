//! Runner generation: `tb.Directives` in, the testbench's Zig source out
//! (fixed-grid, mixed-signal, or the Clause 12 VPI library form).
//! LRM: §1, §2.8.3, §3.4, §3.4.1, §3.4.5, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.1,
//! §4.6.4.3, §4.6.4.6, §5.10.2, §6.3.4, §8.2, §9.19.
//!
//! Order: the compile facts a caller copies into `Directives` first, then the
//! three renderers, then the pieces they share in the order `renderRunner`
//! writes them: the head, the card, the point's unknowns, and the checks of
//! the device tables. Every byte written here is a testbench's source, which
//! the goldens (`--emit-zig`) do not cover; the fixture suite does.

const std = @import("std");
const tb = @import("../root.zig");
const tb_runner_text = @import("runner_text.zig");
const naming = @import("ir").names;
const Lowered = @import("ir").Lowered;
const HeldVar = Lowered.HeldVar;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Error = tb.Error;
const Sweep = tb.Sweep;
const Directives = tb.Directives;
const max_points = tb.max_points;
const assert = std.debug.assert;

comptime {
    // `expand`'s cell block is `total * dims`, with `1 <= total <= max_points`.
    assert(max_points > 0);
}

/// Returns the `//! param` lines that name a shape parameter of `lowered`
/// (`ParamInfo.shape`, §3.4), allocated in `arena`. A shape parameter is fixed
/// at compile time, so a non-empty result means the caller must compile again
/// with it as `Options.param_overrides`, as `--param` would.
pub fn shapeOverrides(arena: Allocator, d: Directives, lowered: *const Lowered) Allocator.Error![]const Lowered.ParamOverride {
    var out: std.ArrayList(Lowered.ParamOverride) = .empty;
    for (d.params) |card| for (lowered.params.items) |p| {
        if (p.shape and std.mem.eql(u8, p.name, card.name)) try out.append(arena, .{ .name = card.name, .value = card.value });
    };
    return out.items;
}

/// Returns the bytes of `lowered`'s §3.2.2 memory-backed arrays
/// (`Directives.mem_bytes`): eight per element, real or integer. Plus the
/// IEEE 1364 §5.4 wide temporaries (`wide_kernels.zig`): one value per node
/// of every sized tree and the division's scratch, three values' bytes per
/// node (docs/specification/Vague_Decisions.md §7, "wide `reg` temporaries").
pub fn memBytes(lowered: *const Lowered) u64 {
    var n: u64 = 0;
    for (lowered.mem_arrays.items) |m| n += 8 * @as(u64, m.len);
    for (lowered.wide_nodes.items) |w| n += 3 * 4 * ((@as(u64, w.width) + 31) / 32);
    return n;
}

/// Returns the `U` indices of the §4.5.2 operator unknowns
/// (`Directives.op_states`), ascending, allocated in `arena`.
pub fn opStates(arena: Allocator, lowered: *const Lowered) Error![]const u32 {
    const kinds = lowered.nodes.items(.kind);
    var n: usize = 0;
    for (kinds) |k| n += @intFromBool(k == .op_state);
    const out = try arena.alloc(u32, n);
    n = 0;
    for (kinds, 0..) |k, i| switch (k) {
        .op_state => {
            out[n] = @intCast(i);
            n += 1;
        },
        .net, .branch_flow, .port_flow => {},
    };
    assert(n == out.len);
    // Ascending, as `Directives.op_states` promises.
    for (out[0..n -| 1], out[@min(n, 1)..]) |a, b| assert(a < b);
    return out;
}

/// Returns the mixed-signal plan of a compile, or null for a module with no
/// discrete half that needs the event queue (`Lowered.mixed_signal`). The
/// slices borrow from `lowered` and `mir`.
pub fn mixedPlan(lowered: *const Lowered, mir: *const Mir) ?tb.Mixed {
    if (!lowered.mixed_signal) return null;
    return .{
        .source = lowered.src,
        .top = mir.name,
        .timescales = lowered.timescales,
        .inputs = lowered.discrete_inputs.keys(),
        .snaps = lowered.discrete_snaps.keys(),
        .xz = lowered.discrete_xz.keys(),
        .wide = lowered.discrete_words.keys(),
        .words = lowered.discrete_words.values(),
        .events = lowered.discrete_events.values(),
        .inserts = lowered.inserts,
        .reads = lowered.discrete_reads.keys(),
        .probe_names = lowered.discrete_probes.keys(),
        .probe_nodes = lowered.discrete_probes.values(),
        .held = lowered.held_vars.items,
        .params = lowered.params.items,
        .param_reads = lowered.discrete_params.keys(),
    };
}

/// Adds W0750 to `bag` at the first §5.10.3 `cross`, `above` or `timer`
/// call when the module gets the fixed-grid runner (`mixedPlan` is null),
/// which inserts no timepoint: such an event fires at the first `//! time`
/// point past its own time.
pub fn warnGridEvents(bag: *diag.Bag, lowered: *const Lowered, mir: *const Mir) !void {
    if (lowered.mixed_signal) return;
    for (0..mir.blockCount()) |bi| {
        var insts = mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (insts.next()) |inst| {
            if (mir.instOp(inst) != .call or mir.instTok(inst) == Mir.no_tok) continue;
            const k = Mir.callee.opKind(mir.instData(inst).call.callee);
            if (k == .cross or k == .above or k == .timer)
                return bag.add(.codegen, .W0750, lowered.tokenSpan(mir.instTok(inst)), "the testbench inserts no timepoint at it", .{});
        }
    }
}

/// Returns the runner's Zig source, allocated in `arena`; dispatches to
/// `renderMixed` when `d.mixed` is set. `title` keys each transcript block
/// (the fixture's file stem). All output goes to stderr via `std.debug.print`,
/// the stream generated `$strobe` uses, so the interleaving is deterministic.
/// Fails with `error.TooManyPoints` past `max_points`.
pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    if (d.mixed) |mx| return renderMixed(arena, title, d, mx);
    var out: std.ArrayList(u8) = .empty;

    try head(&out, arena, title, d);

    // --- main -------------------------------------------------------------
    try out.appendSlice(arena, tb_runner_text.big_stack_text);
    try out.appendSlice(arena,
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    if (comptime big_stack) return bigStack(init);
        \\    @call(.never_inline, run, .{init});
        \\}
        \\fn run(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| try setCard(&out, arena, "    ", "model", p.name, p.value);
    // §6.3.4: the card is complete only now. Unconditional, so a §3.4.5
    // localparam is derived even with no `//! param` line.
    try deriveCard(&out, arena, "    ", "model", d.temp);
    try out.appendSlice(arena,
        \\
        \\    var inst: D.Instance = .{};
        \\
    );
    try out.print(arena, "    run_kind = .{t};\n    sim_state = .{{ .kind = run_kind }};\n", .{d.analysis});
    // §2.8.3/§12.32: this testbench is a host, so it binds `no_vpi_app` for
    // the device's unresolved `$name`s and passes `validateHost` like any other.
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    // §9.15 Table 9-28 through the GPU-safe channel a GPU host uses: the
        \\    // bytes in `contract.host_strings`, the row only their indices. The
        \\    // `Instance.cwd`/`analysis_name` slices stay "", so a device that
        \\    // read them instead answers "" and its fixture fails.
        \\    var tb_strings = [_][]const u8{ "", "", analysis_name };
        \\    if (comptime @hasField(D.Model, "cwd_idx__")) {
        \\        tb_strings[1] = cwdPath();
        \\        contract.host_strings = &tb_strings;
        \\        model.cwd_idx__ = 1;
        \\        model.analysis_name_idx__ = 2;
        \\    }
        \\    // The solve-invariant slice: after the card and the temperature
        \\    // write, before the first evaluation — the ordering a host keeps.
        \\    // With `Dual` itself as the value scalar, so every latched value is
        \\    // the bits `eval` would have computed.
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
        \\    // §4.6.2 one per analysis: `initState` at each analysis's first point.
        \\    var state: State = undefined;
        \\    _ = &state;
        \\
    );
    try out.appendSlice(arena,
        \\
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\
    );

    // --- §4.6.4 the exported noise topology ---------------------------------
    // Once, before the points: `noise_gens` is a comptime table.
    if (d.asserts_noise) {
        try out.appendSlice(arena,
            \\
            \\    // §4.6.4: what this device tells a host about its noise
            \\    // generators. Nothing in the model's own text can see this —
            \\    // §4.6.2 makes every source read 0 outside a small-signal
            \\    // analysis — so the table is the only place the clause is
            \\    // observable, and a `//! noise` line is how a fixture reaches it.
            \\    {
            \\        const want = [_][]const u8{
            \\
        );
        for (d.noise) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
        try out.appendSlice(arena,
            \\        };
            \\        if (comptime @hasDecl(D, "noise_gens")) {
            \\            std.debug.print("noise count got={d} want={d} ok={d}\n", .{
            \\                D.noise_gens.len, want.len, @intFromBool(D.noise_gens.len == want.len),
            \\            });
            \\            inline for (D.noise_gens, 0..) |g, i| {
            \\                // `U`'s tag names ARE the spelling contract — the same
            \\                // names a `//! bias` line uses and the same ones a
            \\                // diagnostic prints — so a fixture writes what it reads
            \\                // in the source.
            \\                // `#k` is §4.6.4.6's correlation column: two rows
            \\                // printing the same `#k` share one physical generator;
            \\                // `#null` is a row that declared no identity.
            \\                // Every field is comptime, so the row is too, at any length.
            \\                const got = comptime std.fmt.comptimePrint("{s}({s},{s})#{?d}", .{
            \\                    @tagName(g.kind),
            \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.row)))),
            \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.col)))),
            \\                    g.source,
            \\                });
            \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
            \\                std.debug.print("noise[{d}] got={s} want={s} ok={d}\n", .{
            \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
            \\                });
            \\            }
            \\        } else {
            \\            // No table at all is the empty table: a device that
            \\            // declares no generator does not declare an empty one.
            \\            std.debug.print("noise count got=0 want={d} ok={d}\n", .{
            \\                want.len, @intFromBool(want.len == 0),
            \\            });
            \\        }
            \\    }
            \\
        );
        try emitNoiseComptime(arena, &out, d);
    }

    // --- §4.6.3 the exported AC stimulus topology ---------------------------
    if (d.asserts_acstim) try emitAcTopology(arena, &out, d);

    // --- §5.6.1.2 the exported charge sites ---------------------------------
    if (d.asserts_qsite) try emitQSites(arena, &out, d);

    // --- §9.17.3 the published cold start -----------------------------------
    if (d.asserts_seed) try emitSeedCheck(arena, &out, d);

    // --- §2.9.2 the published descriptions and units ------------------------
    if (d.asserts_meta) try emitMeta(arena, &out, d);

    // --- §3.6.1.2 the published tolerances ----------------------------------
    for (d.abstols) |b| try out.print(arena,
        \\    if (comptime std.meta.stringToEnum(D.U, "{0f}")) |u| {{
        \\        const g = u_abstol[@backingInt(u)];
        \\        std.debug.print("abstol[{0f}] got={{e}} want={{e}} ok={{d}}\n", .{{ g, @as(f64, {1f}), @intFromBool(near(g, {1f})) }});
        \\    }} else std.debug.print("abstol[{0f}] got=none want={{e}} ok=0\n", .{{@as(f64, {1f})}});
        \\
    , .{ std.zig.fmtString(b.name), fmtF64(b.value) });

    // --- one straight-line block per operating point ------------------------
    // Sweep outer, time inner. With `//! time` each sweep point is its own
    // transient run with a fresh `State`, so no bias inherits another's §4.5
    // operator history or §4.6.2 variables; a dc sweep's points share them.
    const points = try expand(arena, d);
    assert(points.len != 0);
    // `parse` gives every grid at least one time (`Directives.times`).
    assert(d.times.len != 0);
    // §5.10.2 / Table 5-1: `initial_step` fires on an analysis's first point
    // and `final_step` on its last. With `//! time` each sweep block is its own
    // transient analysis; without it the blocks are the steps of one dc sweep.
    // A one-point fixture gets both events, as Table 5-1's DCOP column does.
    const per_block = d.times.len > 1;
    var n: usize = 0;
    // `//! psweep` gives each point its own model card: §8.2 sub-tasks, each
    // re-derived per §6.3.4. Without it the shared `model` is used.
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points) |pt| {
        try out.appendSlice(arena, "    {\n");
        try sweepPoint(&out, arena, d, pt);
        // §9.5.1.1 a block after the first is a following analysis of the same
        // process, so a file it reopens "w" keeps earlier output.
        if (per_block and n != 0)
            try out.appendSlice(arena, "        if (comptime contract.fileIo(D)) |f| if (f.new_analysis) |g| g();\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| try setCard(&out, arena, "        ", "pm", s.name, v);
            try deriveCard(&out, arena, "        ", "pm", null);
            // §6.3.4: setup also derives from the swept card.
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"setup\")) D.setup(Dual, &pm);\n");
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"setupInstance\")) D.setupInstance(&pm, &inst);\n");
        }
        // §4.6.2 a new analysis re-initializes its variables (`initState`);
        // the steps of one dc sweep are one analysis and keep them.
        try pointUnknowns(&out, arena, d, pt, mdl, per_block or n == 0);
        for (d.times, 0..) |t, k| {
            // `locate` draws a wave between the last accepted point and this.
            if (d.waves.len != 0) try out.appendSlice(arena, "        forced_prev = forced;\n");
            for (d.waves) |wv| {
                assert(wv.values.len != 0); // `parseNumbers` refuses an empty list.
                // A short `wave` holds its last value.
                const v = wv.values[@min(k, wv.values.len - 1)];
                try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(wv.name), fmtF64(v) });
            }
            // The first time is the DC point, dt = 0, which operator kernels
            // answer with their DC form (§4.5.4 initial condition, §4.5.11 DC
            // gain), and which `atPoint` makes a transient's "ic" (Table 4-22).
            const dt: f64 = if (k == 0) 0.0 else d.times[k] - d.times[k - 1];
            try out.print(arena, "        atPoint({f}, {f});\n", .{ fmtF64(t), fmtF64(dt) });
            // Written at every point: a stale `true` would fire an event twice.
            try out.print(arena, "        sim_state.initial_step = {};\n        sim_state.final_step = {};\n", .{
                k == 0 and (per_block or n == 0),
                k + 1 == d.times.len and (per_block or n + 1 == points.len),
            });
            // §5.2.1 `analog initial` re-runs per sub-task: the first time of
            // every block, unlike `initial_step` (visible under `//! psweep`).
            try out.print(arena, "        sim_state.analog_initial = {};\n", .{k == 0});
            // §5.6 the model prints at a solution: solve first, then `point`.
            try out.print(arena, "        var solved{d} = solve(&x, &forced, &{s}, &inst);\n", .{ n, mdl });
            // §5.10.3.1 a crossing found outside its tolerance box gets its
            // own point first (`locate`), and this one is solved again.
            try out.print(arena, "        if (crossRetry(&{1s}, &inst, &x, &state)) |r| solved{0d} = locate(r, {0d}, &x, &forced, &{1s}, &inst, &state, 0);\n", .{ n, mdl });
            try out.print(arena, "        point({d}, &x, &{s}, &inst);\n", .{ n, mdl });
            // §4.6.4.1/.2 the PSD depends on bias; fixtures state it at the
            // first point, the one every fixture has.
            if (n == 0) try emitNoisePsd(arena, &out, d, mdl);
            // §4.6.3 magnitude and phase may read the card (`mdl`); also
            // stated at the first point.
            if (n == 0) try emitAcStim(arena, &out, d, mdl);
            // `acDyn` linearizes at the point `eval` does; also the first.
            if (n == 0) try emitAcDyn(arena, &out, d, mdl);
            // §9.17.3 the published clamp, with this point's `x` as `cur`.
            if (n == 0) try emitLimitCheck(arena, &out, d, mdl);
            // §4.5.2 accepted-step bookkeeping: only `updateState` writes the
            // history `eval` reads.
            // VerA's `$vera_reject_step`: a rejected step is retried (`retry`).
            try out.print(arena, "        if (stepPost(&{s}, &inst, &x, &state, solved{d})) |r| retry(r, {d}, &x, &forced, &{s}, &inst, &state, 0);\n", .{ mdl, n, n, mdl });
            n += 1;
        }
        try out.appendSlice(arena, "    }\n");
    }
    // One block of `d.times` per point.
    assert(n == points.len * d.times.len);

    try out.print(arena, "}}\n\nconst print_residual = {};\n", .{d.print_residual});
    return out.items;
}

/// Returns the VAMS §8 mixed-signal runner, allocated in `arena`: the same
/// device and solver, with operating points from `sim.mixed.run` (declared
/// `//! time`s plus every implicit D2A time) and discrete inputs from the
/// digital half, re-elaborated at startup. A `//! wave` is piecewise linear
/// here, equal to the fixed-grid runner's value at every declared point.
/// Device-table directives (noise, acstim, qsite, seed, limit) are a compile
/// error in the emitted runner.
fn renderMixed(arena: Allocator, title: []const u8, d: Directives, mx: tb.Mixed) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try head(&out, arena, title, d);
    try out.appendSlice(arena, tb_runner_text.mixed_body);
    if (d.asserts_noise or d.asserts_acstim or d.asserts_qsite or d.asserts_seed or d.asserts_meta or d.limits.len != 0 or d.acdyn.len != 0)
        try out.appendSlice(arena, "comptime { @compileError(title ++ \": //! noise, //! acstim, //! qsite, //! seed, //! meta, //! limit and //! acdyn are not read by the mixed-signal runner\"); }\n");

    try out.print(arena, "const mixed_source = \"{f}\";\n", .{std.zig.fmtString(mx.source)});
    try out.print(arena, "const mixed_top = \"{f}\";\n", .{std.zig.fmtString(mx.top)});
    try out.appendSlice(arena, "const mixed_timescales = [_]TimescaleEvent{");
    for (mx.timescales) |ev| if (ev.value) |t|
        try out.print(arena, " .{{ .at = {d}, .value = .{{ .unit = {f}, .precision = {f} }} }},", .{ ev.at, fmtF64(t.unit), fmtF64(t.precision) })
    else
        try out.print(arena, " .{{ .at = {d}, .value = null }},", .{ev.at});
    try out.appendSlice(arena, " };\n");
    try timeArrays(&out, arena, d);

    // The adapter: `sim.mixed.run`'s `A`.
    try out.appendSlice(arena,
        \\
        \\const Analog = struct {
        \\    model: *D.Model,
        \\    inst: *D.Instance,
        \\    x: *[n_u]f64,
        \\    forced: *[n_u]?f64,
        \\    state: *State,
        \\    dout: *std.Io.Writer.Allocating,
        \\    n: *usize,
        \\    slots: [input_ports.len]u32,
        \\    snap_slots: [snap_ports.len]u32,
        \\    /// §7.3.6.4 the digital slots `a2d_ports` are copied into.
        \\    dig: *sim.digital.Run,
        \\    a2d_slots: [a2d_ports.len]u32,
        \\    /// §8.5.3.6 the region-1b values of the last explicit D2A event.
        \\    snaps: [snap_ports.len]f64 = @splat(0),
        \\    /// §7.3.6.1 each `a2d_ports` count as the last finished solution left it.
        \\    counts: [a2d_ports.len]i64 = @splat(0),
        \\    t: f64 = 0.0,
        \\    solved: bool = false,
        \\    /// The last finished solution, for §7.3.6.3's interpolation.
        \\    x_prev: [n_u]f64 = @splat(0.0),
        \\    t_prev: ?f64 = null,
        \\
        \\    /// §7.3.6.5 / Table 7-1: every input as the integer the digital
        \\    /// engine holds for the latest tick, the guarded reads' snapshot, and
        \\    /// the explicit D2A terms delivered to this solve. The fields are
        \\    /// parameters to the device, so its parameter-only prep is redone.
        \\    pub fn setInputs(a: *Analog, dig: *sim.digital.Run, fired: u64) !void {
        \\        a.flush();
        \\        // A `reg` past 32 bits is one port per word (`Lowered.discrete_words`).
        \\        @setEvalBranchQuota(1000 + 100 * input_ports.len);
        \\        inline for (input_ports, 0..) |p, i| if (p.xz) |xz| {
        \\            // §7.3.2 read four-state: both planes, and x or z is a value.
        \\            const v = dig.values[a.slots[i]];
        \\            setField(a.model, p.field, v.asInt() orelse @as(i64, @bitCast(v.values()[0])));
        \\            setField(a.model, xz, @as(i64, @bitCast(v.unknowns()[0])));
        \\        } else if (p.word) |k| {
        \\            setField(a.model, p.field, mixedWord(dig, a.slots[i], p.name, k));
        \\        } else setField(a.model, p.field, mixedInput(dig, a.slots[i], p.name));
        \\        inline for (snap_ports, 0..) |p, i| setField(a.model, p.field, a.snaps[i]);
        \\        inline for (event_ports, 0..) |p, k| setField(a.model, p.field, @intFromBool(fired >> k & 1 != 0));
        \\        if (comptime @hasDecl(D, "setup")) D.setup(Dual, a.model);
        \\        if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(a.model, a.inst);
        \\    }
        \\
        \\    /// §5.10.3.3 the device's next timer instant after `t`, if it has one.
        \\    pub fn breakpoint(a: *Analog, t: f64) ?f64 {
        \\        const m: ?f64 = if (comptime @hasDecl(D, "nextBreakpoint")) D.nextBreakpoint(a.model, t) else null;
        \\        const i: ?f64 = if (comptime @hasDecl(D, "pendingBreakpoint")) D.pendingBreakpoint(a.inst, t) else null;
        \\        return if (m != null and i != null) @min(m.?, i.?) else m orelse i;
        \\    }
        \\
        \\    pub fn snapshot(a: *Analog, dig: *sim.digital.Run) !void {
        \\        inline for (snap_ports, 0..) |p, i| a.snaps[i] = mixedInput(dig, a.snap_slots[i], p.name);
        \\    }
        \\
        \\    /// §8.5.3.6 one region-1b evaluation: what the tentative solution's
        \\    /// explicit D2A event statements assigned (`d2a_held`) is committed,
        \\    /// and no other history moves, so the tick's own solution still
        \\    /// steps from the last finished one.
        \\    pub fn latch(a: *Analog) !void {
        \\        if (comptime State != void and d2a_held.len != 0) {
        \\            const inst = a.accepted();
        \\            inline for (d2a_held) |f| @field(a.inst, f) = @field(inst, f);
        \\        }
        \\    }
        \\
        \\    /// The `Instance` the tentative solution would leave if accepted.
        \\    fn accepted(a: *const Analog) D.Instance {
        \\        var inst = a.inst.*;
        \\        var state = a.state.*;
        \\        _ = D.updateState(Val, a.model, &inst, a.x.*, &state, sim_state);
        \\        return inst;
        \\    }
        \\
        \\    /// VAMS §7.3.3 / §7.3.6.3 a continuous variable no event statement
        \\    /// assigns, read by a digital expression: its value on the tentative
        \\    /// solution, which `sim.mixed.run` steps to every digital event
        \\    /// time (`has_probes`) before the digital engine runs it.
        \\    // ponytail: the solution's value, not one interpolated to the
        \\    // tick: they differ only where an A2D crossing rounds to a tick.
        \\    fn publish(a: *Analog) !void {
        \\        if (comptime State != void and has_free_reads) {
        \\            const inst = a.accepted();
        \\            inline for (a2d_ports, 0..) |p, i| if (p.free) try a2dPut(a.dig, a.a2d_slots[i], @field(inst, p.field), false);
        \\        }
        \\    }
        \\
        \\    pub fn solveAt(a: *Analog, t: f64, dt: f64, first: bool, last: bool) !void {
        \\
    );
    for (d.waves, 0..) |wv, k|
        try out.print(arena, "        set(a.x, a.forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try out.appendSlice(arena,
        \\        atPoint(t, dt);
        \\        sim_state.initial_step = first;
        \\        sim_state.final_step = last;
        \\        sim_state.analog_initial = first;
        \\        a.solved = solve(a.x, a.forced, a.model, a.inst);
        \\        a.t = t;
        \\        try a.publish();
        \\    }
        \\
        \\    pub fn finish(a: *Analog) !void {
        \\        a.flush();
        \\        point(a.n.*, a.x, a.model, a.inst);
        \\        if (stepPost(a.model, a.inst, a.x, a.state, a.solved)) |r| retryUnsupported(r);
        \\        // §7.3.6.4: what the accepted solution left in each held variable.
        \\        inline for (a2d_ports, 0..) |p, i| {
        \\            const assigned = if (p.count) |c| blk: {
        \\                const n: i64 = @field(a.inst, c);
        \\                defer a.counts[i] = n;
        \\                break :blk n != a.counts[i];
        \\            } else false;
        \\            try a2dPut(a.dig, a.a2d_slots[i], @field(a.inst, p.field), assigned);
        \\        }
        \\        a.n.* += 1;
        \\        a.x_prev = a.x.*;
        \\        a.t_prev = a.t;
        \\    }
        \\
        \\    /// VAMS §7.3.6.3 `V(n1)` / `V(n1, n2)` for a digital expression: the
        \\    /// tentative solution (`t` null), or the value "calculated for the
        \\    /// time corresponding to a real promotion of the digital time",
        \\    /// linear between the last finished solution and the tentative one.
        \\    pub fn probe(a: *Analog, t: ?f64, n1: []const u8, n2: ?[]const u8) !f64 {
        \\        const now = try potential(a.x, n1, n2);
        \\        const tq = t orelse return now;
        \\        const tp = a.t_prev orelse return now;
        \\        if (tq >= a.t or a.t <= tp) return now;
        \\        const before = try potential(&a.x_prev, n1, n2);
        \\        if (tq <= tp) return before;
        \\        return before + (now - before) * (tq - tp) / (a.t - tp);
        \\    }
        \\
        \\    /// The digital half's own §17 output, in time order with the analog
        \\    /// points: everything it printed up to the tick being solved.
        \\    fn flush(a: *Analog) void {
        \\        std.debug.print("{s}", .{a.dout.written()});
        \\        a.dout.clearRetainingCapacity();
        \\    }
        \\};
        \\
        \\
    );
    // Each digital name beside its `Model` field.
    try out.appendSlice(arena, "const input_ports = [_]Port{");
    for (mx.inputs) |name| {
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\"", .{ std.zig.fmtString(name), try naming.sanitizeAlloc(arena, name) });
        const xz = for (mx.xz) |x| {
            if (std.mem.eql(u8, x, name)) break true;
        } else false;
        if (xz) {
            const field = try naming.sanitizeAlloc(arena, try naming.xzField(arena, name));
            try out.print(arena, ", .xz = \"{s}\"", .{field});
        }
        // §7.3.1 a `reg` wider than 32 bits: word 0 exactly, then one port
        // per further word, each its own `Model` field.
        const n_words = for (mx.wide, mx.words) |w, n| {
            if (std.mem.eql(u8, w, name)) break n;
        } else 0;
        if (n_words != 0 and !xz) try out.appendSlice(arena, ", .word = 0");
        try out.appendSlice(arena, " },");
        for (1..@max(n_words, 1)) |k| {
            const field = try naming.sanitizeAlloc(arena, try naming.wordField(arena, name, k));
            try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\", .word = {d} }},", .{ std.zig.fmtString(name), field, k });
        }
    }
    try out.appendSlice(arena, " };\nconst snap_ports = [_]Port{");
    for (mx.snaps) |name| {
        const field = try naming.sanitizeAlloc(arena, try naming.snapField(arena, name));
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(name), field });
    }
    try out.appendSlice(arena, " };\nconst event_ports = [_]EventPort{");
    for (mx.events) |ev| try out.print(arena, " .{{ .name = \"{f}\", .edge = .{t}, .field = \"{s}\" }},", .{ std.zig.fmtString(ev.name), ev.edge, try naming.sanitizeAlloc(arena, ev.param) });
    try out.appendSlice(arena, " };\n");
    // VAMS §7.8.4 the inserted connect modules, which the source the digital
    // half re-elaborates does not hold (`sim.digital.Insert`).
    try out.appendSlice(arena, "const mixed_inserts = [_]sim.digital.Insert{");
    for (mx.inserts) |row| {
        try out.appendSlice(arena, " .{");
        inline for (@typeInfo(@TypeOf(row)).@"struct".field_names) |name|
            try out.print(arena, " .{s} = \"{f}\",", .{ name, std.zig.fmtString(@field(row, name)) });
        try out.appendSlice(arena, " },");
    }
    try out.appendSlice(arena, " };\n");
    // VAMS §7.3.6.4 each analog variable a digital expression reads, beside
    // the §5.10 held `Instance` field its value is copied from. A variable
    // that is not held is left out, and the digital half refuses the read.
    try out.appendSlice(arena, "const a2d_ports = [_]Port{");
    for (mx.reads) |name| for (mx.held) |h| if (std.mem.eql(u8, h.name, name)) {
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\", .free = {}", .{ std.zig.fmtString(name), try naming.heldField(arena, mx.top, name), h.why != .event });
        // §7.3.6.1 its assignment count, when it has one.
        for (mx.held) |c| if (std.mem.startsWith(u8, c.name, HeldVar.assign_count_prefix) and std.mem.eql(u8, c.name[HeldVar.assign_count_prefix.len..], name)) {
            try out.print(arena, ", .count = \"{s}\"", .{try naming.heldField(arena, mx.top, c.name)});
        };
        try out.appendSlice(arena, " },");
        break;
    };
    // VAMS §6.3 the card's root parameters, so the digital half reads the
    // values `Model` gets (`sim.digital.Mixed.params`).
    // §8.5.3.6 the held fields only explicit D2A event statements assign.
    try out.appendSlice(arena, " };\nconst d2a_held = [_][]const u8{");
    for (mx.held) |h| if (h.d2a) {
        try out.print(arena, " \"{s}\",", .{try naming.heldField(arena, mx.top, h.name)});
    };
    try out.appendSlice(arena, " };\nconst mixed_params = [_]sim.digital.Param{");
    for (d.params) |p| try out.print(arena, " .{{ .name = \"{f}\", .value = {f} }},", .{ std.zig.fmtString(p.name), fmtF64(p.value) });
    // The host has already derived these values, including defaults that the
    // digital expression subset cannot evaluate. Copy from each analysis's
    // actual Model, after card writes and per-point parameter overrides.
    try out.appendSlice(arena, " };\nconst mixed_real_ports = [_]Port{");
    for (mx.params) |p| {
        if (p.ty != .real) continue;
        const read = for (mx.param_reads) |name| {
            if (std.mem.eql(u8, p.name, name)) break true;
        } else false;
        if (!read) continue;
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(p.name), try naming.sanitizeAlloc(arena, p.name) });
    }
    try out.appendSlice(arena, " };\nconst mixed_reads = blk: {\n    var names: [a2d_ports.len][]const u8 = undefined;\n    for (a2d_ports, &names) |p, *n| n.* = p.name;\n    const out = names;\n    break :blk out;\n};\n");
    // §7.3.3 / §6.7.1 each digital probe terminal's node pair (`terminal`),
    // as the `D.U` fields spell the nodes.
    try out.appendSlice(arena, "const probe_terminals = std.StaticStringMap([2][]const u8).initComptime(.{");
    for (mx.probe_names, mx.probe_nodes) |name, pair| try out.print(arena, " .{{ \"{f}\", .{{ \"{s}\", \"{s}\" }} }},", .{
        std.zig.fmtString(name),
        try naming.sanitizeAlloc(arena, pair[0]),
        try naming.sanitizeAlloc(arena, pair[1]),
    });
    try out.appendSlice(arena, " });\n\n");

    // --- main ---------------------------------------------------------------
    try out.appendSlice(arena, tb_runner_text.big_stack_text);
    try out.appendSlice(arena,
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    if (comptime big_stack) return bigStack(init);
        \\    @call(.never_inline, run, .{init});
        \\}
        \\fn run(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| try setCard(&out, arena, "    ", "model", p.name, p.value);
    try deriveCard(&out, arena, "    ", "model", d.temp);
    try out.appendSlice(arena, "    var inst: D.Instance = .{};\n");
    try out.print(arena, "    run_kind = .{t};\n    sim_state = .{{ .kind = run_kind }};\n", .{d.analysis});
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    if (comptime @hasField(D.Instance, "cwd")) inst.cwd = cwdPath();
        \\    if (comptime @hasField(D.Instance, "analysis_name")) inst.analysis_name = analysis_name;
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\    var n: usize = 0;
        \\    var state: State = undefined;
        \\
    );
    // Each sweep point is its own analysis: fresh digital elaboration and `State`.
    const points = try expand(arena, d);
    assert(points.len != 0);
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points, 0..) |pt, pi| {
        try out.appendSlice(arena, "    {\n");
        try sweepPoint(&out, arena, d, pt);
        // §9.5.1.1, as in the fixed-grid runner: every point here is an analysis.
        if (pi != 0)
            try out.appendSlice(arena, "        if (comptime contract.fileIo(D)) |f| if (f.new_analysis) |g| g();\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| try setCard(&out, arena, "        ", "pm", s.name, v);
            try deriveCard(&out, arena, "        ", "pm", null);
        }
        try pointUnknowns(&out, arena, d, pt, mdl, true);
        try out.print(arena, "        runMixed(&{s}, &inst, &x, &forced, &state, &n);\n    }}\n", .{mdl});
    }
    try out.print(arena, "}}\n\nconst print_residual = {};\n", .{d.print_residual});
    return out.items;
}

/// Returns a Clause 12 analog host library (§12.7 to §12.10, §12.18,
/// §12.31.3), allocated in `arena`: the device and solver behind a C
/// interface, stepped by a host that owns the time walk (`src/vpi/analog.zig`),
/// since §12.31.3 lets a VPI application force or reject a solution time. It
/// exports: solve at t tentatively, accept the last solution, read x, and read
/// each §5.6 row's value and each instance's share of a shared row (§5.4.1);
/// the device must be compiled with
/// `Options.vpi_contribs`. Only an accepted solve writes history, so a rejected
/// point needs no undo. Every unknown is solved for (§3.6.1) unless a
/// `//! bias`/`//! wave` line pins it.
pub fn renderVpiLib(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try head(&out, arena, title, d);
    try timeArrays(&out, arena, d);
    try out.appendSlice(arena, tb_runner_text.vpi_lib_body);

    // --- open: the card, the instance, the unknowns -----------------------
    try out.appendSlice(arena,
        \\export fn vera_vpi_open(kind: u8) callconv(.c) void {
        \\    g_model = .{};
        \\
    );
    for (d.params) |p| try setCard(&out, arena, "    ", "g_model", p.name, p.value);
    try deriveCard(&out, arena, "    ", "g_model", d.temp);
    try out.appendSlice(arena, "    g_inst = .{};\n");
    try out.appendSlice(arena,
        \\    run_kind = @fromBackingInt(kind);
        \\    sim_state = .{ .kind = run_kind };
        \\    if (comptime @hasDecl(D, "systf_calls")) g_inst.systf = if (host_call != null) &host_systf else &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) g_inst.plusargs = &.{};
        \\    if (comptime @hasField(D.Instance, "cwd")) g_inst.cwd = cwdPath();
        \\    if (comptime @hasField(D.Instance, "analysis_name")) g_inst.analysis_name = @tagName(sim_state.kind);
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &g_model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&g_model, &g_inst);
        \\    g_x = @splat(0.0);
        \\    g_forced = @splat(null);
        \\    if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {
        \\        if (nodeset_i) |v| g_x[i] = v;
        \\    };
        \\
    );
    for (d.bias) |b|
        try out.print(arena, "    set(&g_x, &g_forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    try out.appendSlice(arena,
        \\    g_state = newState(&g_model, &g_inst);
        \\    q_prev = @splat(0.0);
        \\    g_solved = false;
        \\}
        \\
        \\export fn vera_vpi_solve(t: f64, dt: f64, first: bool, last: bool) callconv(.c) bool {
        \\
    );
    for (d.waves, 0..) |wv, k|
        try out.print(arena, "    set(&g_x, &g_forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try out.appendSlice(arena,
        \\    atPoint(t, dt);
        \\    sim_state.initial_step = first;
        \\    sim_state.final_step = last;
        \\    sim_state.analog_initial = first;
        \\    g_solved = solve(&g_x, &g_forced, &g_model, &g_inst);
        \\    return g_solved;
        \\}
        \\
        \\const print_residual = false;
        \\
    );
    return out.items;
}

/// The page every runner opens with: the fixed head, `title`, the fixed body.
fn head(out: *std.ArrayList(u8), arena: Allocator, title: []const u8, d: Directives) Error!void {
    // Every runner starts on an empty buffer: the head is the page's first byte.
    assert(out.items.len == 0);
    try out.appendSlice(arena, tb_runner_text.runner_head);
    try out.print(arena, "/// Read by `contract.validating`: run the contract's conformance checks.\npub const vera_validate_contract = {};\n", .{d.validate_contract});
    try out.print(arena, "/// The switch of `fdCheck`, `finiteCheck` and `stateCheck`: the suite's `--certify`.\nconst fd_certify = {};\n", .{d.certify});
    try out.print(arena, "/// `finiteCheck`'s claim: every contribution unit was proved finite.\nconst finite_proved = {};\n", .{d.finite_proved});
    try out.print(arena, "const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try out.print(arena, "/// `bigStack`'s share for the device's memory-backed arrays.\nconst mem_bytes: usize = {d};\n\n", .{d.mem_bytes});
    // §9.15 `$simparam$str("analysis_name")`: this testbench's one analysis.
    const name = if (d.analysis_name.len != 0) d.analysis_name else @tagName(d.analysis);
    try out.print(arena, "const analysis_name = \"{f}\";\n\n", .{std.zig.fmtString(name)});
    try out.appendSlice(arena, tb_runner_text.runner_body);
}

/// Writes one card line, `<card>.<name> = value`, at `indent`.
fn setCard(out: *std.ArrayList(u8), arena: Allocator, indent: []const u8, card: []const u8, name: []const u8, value: f64) Error!void {
    assert(card.len != 0);
    // §3.4.1/§4.2.1.1 via `cardValue`: a card is written in reals and an
    // integer parameter rounds, away from zero on a tie.
    try out.print(arena, "{s}{s}.{f} = cardValue(@TypeOf({s}.{f}), \"{f}\", {f});\n", .{
        indent, card, std.zig.fmtId(name), card, std.zig.fmtId(name), std.zig.fmtString(name), fmtF64(value),
    });
    // §9.19 `$param_given` reads the bit `setGiven` raises, when codegen emitted one.
    try out.print(arena, "{s}if (comptime @hasDecl(D.Model, \"setGiven\")) {s}.setGiven(\"{f}\");\n", .{
        indent, card, std.zig.fmtString(name),
    });
}

/// Writes the host's §9.7.1/§9.7.3 sweep point for row `pt` of `expand`:
/// `name=value` per swept variable, which `veraDiag` reports in place of the
/// time during a dc sweep. Nothing when nothing is swept.
fn sweepPoint(out: *std.ArrayList(u8), arena: Allocator, d: Directives, pt: []const f64) Error!void {
    assert(pt.len == d.sweeps.len + d.psweeps.len);
    if (pt.len == 0) return;
    try out.appendSlice(arena, "        diag_sweep = \"");
    for (pt, 0..) |v, k| {
        const s = if (k < d.sweeps.len) d.sweeps[k] else d.psweeps[k - d.sweeps.len];
        try out.print(arena, "{s}{f}={d}", .{ if (k == 0) "" else " ", std.zig.fmtString(s.name), v });
    }
    try out.appendSlice(arena, "\";\n");
}

/// Writes, at `indent`, the §9.10 temperature into `card` when `temp` is
/// given (the `Model` row holds it, written with the card), then the §6.3.4
/// `derive` and the shape check that complete it. Every card a runner builds
/// ends this way, after its `setCard` lines.
fn deriveCard(out: *std.ArrayList(u8), arena: Allocator, indent: []const u8, card: []const u8, temp: ?f64) Error!void {
    if (temp) |t| try out.print(arena, "{s}{s}.temperature__ = {f};\n", .{ indent, card, fmtF64(t) });
    try out.print(arena, "{0s}if (comptime @hasDecl(D, \"derive\")) D.derive(Val, &{1s});\n{0s}shapeCheck(&{1s});\n", .{ indent, card });
}

/// Writes one operating point's unknowns for the fixed-grid and mixed
/// runners: `x` and `forced`, the §3.6.3.2 nodeset, a fresh `State` on card
/// `mdl` when the point starts an analysis (`fresh`), then what the
/// directives pin. `pt` is the point's row of `expand`.
fn pointUnknowns(out: *std.ArrayList(u8), arena: Allocator, d: Directives, pt: []const f64, mdl: []const u8, fresh: bool) Error!void {
    // `pt` is an `expand` row: the unknown columns, then the parameter ones.
    assert(pt.len == d.sweeps.len + d.psweeps.len);
    assert(mdl.len != 0);
    // `forced` marks the unknowns the host drives rather than Newton. By
    // default every unknown is tied to the reference; `//! solve` unties
    // the ones no line names. §3.6.3.2 a nodeset is an initial guess: it
    // seeds `x` and does not touch `forced`, so it picks which root Newton
    // finds. It precedes the `//! bias` lines, which override it.
    try out.print(arena,
        \\        var x: [n_u]f64 = @splat(0.0);
        \\        var forced: [n_u]?f64 = @splat({s});
        \\        if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {{
        \\            if (nodeset_i) |v| x[i] = v;
        \\        }};
        \\
    , .{if (d.solve_free) "null" else "0.0"});
    if (fresh) try out.print(arena, "        state = newState(&{s}, &inst);\n", .{mdl});
    // §4.5.2 operator unknowns are never forced (`Directives.op_states`).
    for (d.op_states) |u| try out.print(arena, "        forced[{d}] = null;\n", .{u});
    for (d.bias) |b|
        try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    for (d.sweeps, pt[0..d.sweeps.len]) |s, v|
        try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
}

/// The `//! time` grid as `times`, and each `//! wave` as `wave_<k>`.
fn timeArrays(out: *std.ArrayList(u8), arena: Allocator, d: Directives) Error!void {
    // `parse` gives every grid and every wave at least one value.
    assert(d.times.len != 0);
    try out.appendSlice(arena, "const times = [_]f64{");
    for (d.times, 0..) |t, i| try out.print(arena, "{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(t) });
    try out.appendSlice(arena, " };\n");
    for (d.waves, 0..) |wv, k| {
        assert(wv.values.len != 0);
        try out.print(arena, "const wave_{d} = [_]f64{{", .{k});
        for (wv.values, 0..) |v, i| try out.print(arena, "{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(v) });
        try out.appendSlice(arena, " };\n");
    }
}

/// The relative compare for `white`/`flicker`/`ef`/`points`, emitted locally
/// only where a `//! noise` line asks for a number.
const noise_close =
    \\        const nclose = struct {
    \\            fn f(g: f64, w: f64, rt: f64) bool {
    \\                return @abs(g - w) <= rt * @max(@abs(g), @abs(w));
    \\            }
    \\        }.f;
    \\
;

/// Emits the checks of the comptime §4.6.4 fields: the source label
/// (§4.6.4.1/.2/.3) and the tabulated spectrum (§4.6.4.3/.4), one guarded
/// statement per asserting line.
fn emitNoiseComptime(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    var any_points = false;
    for (d.noise) |w| {
        if (w.points != null or w.psd != null) any_points = true;
    }
    var any = any_points;
    for (d.noise) |w| {
        if (w.name != null or w.interp != null) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "    if (comptime @hasDecl(D, \"noise_gens\")) {\n");
    if (any_points) try out.appendSlice(arena, noise_close);
    for (d.noise, 0..) |w, k| {
        if (w.name == null and w.interp == null and w.points == null and w.psd == null) continue;
        try out.print(arena, "        if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        if (w.name) |nm| try out.print(
            arena,
            "            std.debug.print(\"noise[{d}].name got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                "                D.noise_gens[{d}].name, \"{f}\",\n" ++
                "                @intFromBool(std.mem.eql(u8, D.noise_gens[{d}].name, \"{f}\")),\n" ++
                "            }});\n",
            .{ k, k, std.zig.fmtString(nm), k, std.zig.fmtString(nm) },
        );
        if (w.interp != null or w.points != null or w.psd != null) {
            // Only a `.table` row has a spectrum; `points` on another row
            // FAILs with a reason instead of crashing on `g.table.?`.
            try out.print(arena,
                \\            if (D.noise_gens[{d}].table) |ti| {{
                \\                const tbl = contract.noiseTable(D, &model, ti);
                \\
            , .{k});
            if (w.interp) |ip| try out.print(
                arena,
                "                std.debug.print(\"noise[{d}].interp got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                    "                    @tagName(tbl.interp), \"{s}\",\n" ++
                    "                    @intFromBool(std.mem.eql(u8, @tagName(tbl.interp), \"{s}\")),\n" ++
                    "                }});\n",
                .{ k, ip, ip },
            );
            if (w.points) |pts| {
                // §4.6.4.3 `tbl` is the table as a host reads it,
                // `contract.noiseTable`: the derived row's own sorted copy of
                // the card's knots when a knot is a parameter (`noise_tables`
                // holds only the declared defaults), else `noise_tables`.
                try out.appendSlice(arena,
                    \\                const got_pts = tbl.points;
                    \\
                );
                try out.appendSlice(arena, "                const want_pts = [_][2]f64{");
                for (pts, 0..) |p, i| try out.print(arena, "{s}.{{ {f}, {f} }}", .{
                    if (i == 0) " " else ", ", fmtF64(p[0]), fmtF64(p[1]),
                });
                try out.print(arena,
                    \\ }};
                    \\                var pts_ok = got_pts.len == want_pts.len;
                    \\                if (pts_ok) for (got_pts, want_pts) |g, wp| {{
                    \\                    if (!nclose(g[0], wp[0], {f}) or !nclose(g[1], wp[1], {f})) {{
                    \\                        pts_ok = false;
                    \\                        break;
                    \\                    }}
                    \\                }};
                    \\                std.debug.print("noise[{d}].points got={{any}} want={{any}} ok={{d}}\n", .{{
                    \\                    got_pts, want_pts, @intFromBool(pts_ok),
                    \\                }});
                    \\
                , .{ fmtF64(w.rtol), fmtF64(w.rtol), k });
            }
            if (w.psd) |ps| {
                // §4.6.4.3/.4 the density a host integrates, from the same
                // table: the clause's interpolation and end clamps.
                try out.appendSlice(arena, "                const want_psd = [_][2]f64{");
                for (ps, 0..) |p, i| try out.print(arena, "{s}.{{ {f}, {f} }}", .{
                    if (i == 0) " " else ", ", fmtF64(p[0]), fmtF64(p[1]),
                });
                try out.print(arena,
                    \\ }};
                    \\                var got_psd: [want_psd.len]f64 = undefined;
                    \\                var psd_ok = true;
                    \\                for (want_psd, &got_psd) |fw, *g| {{
                    \\                    g.* = contract.noiseTableAt(tbl, fw[0]);
                    \\                    if (!nclose(g.*, fw[1], {f})) psd_ok = false;
                    \\                }}
                    \\                std.debug.print("noise[{d}].psd got={{any}} want={{any}} ok={{d}}\n", .{{
                    \\                    got_psd, want_psd, @intFromBool(psd_ok),
                    \\                }});
                    \\
                , .{ fmtF64(w.rtol), k });
            }
            try out.print(arena,
                \\            }} else std.debug.print("noise[{d}].table got=none want=a table ok=0\n", .{{}});
                \\
            , .{k});
        }
        try out.appendSlice(arena, "        }\n");
    }
    try out.appendSlice(arena, "    }\n");
}

/// Emits the §4.6.4.1/.2 `white`, `flicker` and `ef` checks, read from
/// `noisePsd` at the enclosing operating point. `mdl` names the card.
fn emitNoisePsd(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    for (d.noise) |w| {
        if (w.needsPoint()) break;
    } else return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"noisePsd\")) {\n");
    try out.appendSlice(arena, noise_close);
    try out.print(arena, "            const psd = D.noisePsd(Dual, x, &{s}, &inst, sim_state);\n", .{mdl});
    for (d.noise, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try out.print(arena, "            if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        // §4.6.4.6: a density is scaled by the square of the use's
        // coefficient, an exponent is not scaled at all.
        const fields = [_]struct { []const u8, ?f64, bool }{
            .{ "white", w.white, true },
            .{ "flicker", w.flicker, true },
            .{ "ef", w.ef, false },
        };
        for (fields) |f| {
            const want = f[1] orelse continue;
            const got = if (f[2])
                try arena.print("psd[{d}].{s} * psd[{d}].coeff * psd[{d}].coeff", .{ k, f[0], k, k })
            else
                try arena.print("psd[{d}].{s}", .{ k, f[0] });
            try out.print(
                arena,
                "                std.debug.print(\"noise[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    {s}, {f},\n" ++
                    "                    @intFromBool(nclose({s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], got, fmtF64(want), got, fmtF64(want), fmtF64(w.rtol) },
            );
        }
        // §4.6.4.6 the correlation coefficient of rows k and j, from what a
        // host is handed: one shared `source` is one generator, so the two
        // contributions move together, scaled by `coeff_k` and `coeff_j`,
        // and ρ is the sign of their product; a `corr_with` link carries a
        // partial ρ; anything else is independent. A zero coefficient makes
        // ρ 0/0, a NaN that compares false.
        for (w.corrs) |c| try out.print(arena,
            \\                if (comptime D.noise_gens.len > {1d}) {{
            \\                    const sgn = (psd[{0d}].coeff * psd[{1d}].coeff) / (@abs(psd[{0d}].coeff) * @abs(psd[{1d}].coeff));
            \\                    const linked = if (psd[{0d}].corr_with) |o| o == {1d} else false;
            \\                    const back = if (psd[{1d}].corr_with) |o| o == {0d} else false;
            \\                    const rho: f64 = if ({0d} == {1d}) 1.0
            \\                        else if (D.noise_gens[{0d}].source != null and D.noise_gens[{0d}].source == D.noise_gens[{1d}].source) sgn
            \\                        else if (linked) psd[{0d}].corr * sgn
            \\                        else if (back) psd[{1d}].corr * sgn
            \\                        else 0.0;
            \\                    std.debug.print("noise[{0d}].corr[{1d}] got={{d}} want={{d}} ok={{d}}\n", .{{ rho, @as(f64, {2f}), @intFromBool(nclose(rho, {2f}, {3f})) }});
            \\                }} else std.debug.print("noise[{0d}].corr[{1d}] got=none want={{d}} ok=0\n", .{{@as(f64, {2f})}});
            \\
        , .{ k, c.with, fmtF64(c.rho), fmtF64(w.rtol) });
        try out.appendSlice(arena, "            }\n");
    }
    try out.appendSlice(arena, "        }\n");
}

/// Emits the comptime §2.9.2 `decl_meta` checks: the row count, then each row
/// printed as `//! meta` writes it (`tb.Directives.meta`).
fn emitMeta(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §2.9.2/§3.2.1/§3.4.3/§3.6.3.1: the `desc` and `units` a host shows
        \\    // in help messages and operating-point reports. The model's own
        \\    // text cannot read an attribute back, so `decl_meta` is the only
        \\    // place the clauses are observable.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (d.meta) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e)});
    try out.appendSlice(arena,
        \\        };
        \\        if (comptime @hasDecl(D, "decl_meta")) {
        \\            std.debug.print("meta count got={d} want={d} ok={d}\n", .{
        \\                D.decl_meta.len, want.len, @intFromBool(D.decl_meta.len == want.len),
        \\            });
        \\            inline for (D.decl_meta, 0..) |m, i| {
        \\                const got = comptime row: {
        \\                    const dsc: []const u8 = if (m.desc) |v| " desc=\"" ++ v ++ "\"" else "";
        \\                    const uni: []const u8 = if (m.units) |v| " units=\"" ++ v ++ "\"" else "";
        \\                    break :row @tagName(m.kind) ++ " " ++ m.name ++ dsc ++ uni;
        \\                };
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("meta[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\            }
        \\        } else {
        \\            // No table at all is the empty table, for the reason the
        \\            // `noise_gens` block gives.
        \\            std.debug.print("meta count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Emits the comptime §4.6.3 `ac_gens` checks: source count, branch and
/// analysis name, in one block.
fn emitAcTopology(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §4.6.3: what this device tells a host about its AC stimuli. The
        \\    // model's own text cannot see this either — what a `CHECK` on
        \\    // `ac_stim` reads back is the residual's real part, `mag*cos(phase)`
        \\    // — so the phasor leaves through `ac_gens`/`acStim` and a
        \\    // `//! acstim` line is how a fixture reaches it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (d.acstim) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
    try out.appendSlice(arena, "        };\n");
    // A parallel `?[]const u8` column: `inline for` makes the index comptime,
    // so one lookup covers every line.
    try out.appendSlice(arena, "        const want_name = [_]?[]const u8{");
    for (d.acstim, 0..) |e, i| {
        if (e.name) |nm|
            try out.print(arena, "{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(nm) })
        else
            try out.print(arena, "{s}null", .{if (i == 0) " " else ", "});
    }
    try out.appendSlice(arena,
        \\ };
        \\        _ = &want_name;
        \\        if (comptime @hasDecl(D, "ac_gens")) {
        \\            std.debug.print("acstim count got={d} want={d} ok={d}\n", .{
        \\                D.ac_gens.len, want.len, @intFromBool(D.ac_gens.len == want.len),
        \\            });
        \\            inline for (D.ac_gens, 0..) |g, i| {
        \\                // `U`'s tag names ARE the spelling contract, same as the
        \\                // `//! noise` block and the same as `//! bias`.
        \\                const got = comptime std.fmt.comptimePrint("({s},{s})", .{
        \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.row)))),
        \\                    @tagName(@as(D.U, @fromBackingInt(@intCast(g.col)))),
        \\                });
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("acstim[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\                if (i < want_name.len) if (want_name[i]) |wn| {
        \\                    std.debug.print("acstim[{d}].name got={s} want={s} ok={d}\n", .{
        \\                        i, g.name, wn, @intFromBool(std.mem.eql(u8, g.name, wn)),
        \\                    });
        \\                };
        \\            }
        \\        } else {
        \\            // No table at all is the empty table, for the reason the
        \\            // `noise_gens` block gives.
        \\            std.debug.print("acstim count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Emits the §4.6.3 `mag` and `phase` checks, read from `acStim` at the
/// enclosing operating point (A.8.2 makes both `analog_expression`s, so they
/// may depend on bias). `mdl` names the card.
fn emitAcStim(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    for (d.acstim) |w| {
        if (w.needsPoint()) break;
    } else return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"acStim\")) {\n");
    try out.appendSlice(arena, noise_close);
    try out.print(arena, "            const stim = D.acStim(Val, x, &{s}, &inst, sim_state);\n", .{mdl});
    for (d.acstim, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try out.print(arena, "            if (comptime D.ac_gens.len > {d}) {{\n", .{k});
        const fields = [_]struct { []const u8, ?f64 }{ .{ "mag", w.mag }, .{ "phase", w.phase } };
        for (fields) |f| {
            const want = f[1] orelse continue;
            try out.print(
                arena,
                "                std.debug.print(\"acstim[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    stim[{d}].{s}, {f},\n" ++
                    "                    @intFromBool(nclose(stim[{d}].{s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], k, f[0], fmtF64(want), k, f[0], fmtF64(want), fmtF64(w.rtol) },
            );
        }
        try out.appendSlice(arena, "            }\n");
    }
    try out.appendSlice(arena, "        }\n");
}

/// Emits the `//! acdyn` checks (`tb.AcDynWant`): `acDyn`'s term at each named
/// slot and frequency, at the enclosing operating point. `mdl` names the card.
fn emitAcDyn(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    for (d.acdyn) |w| {
        try out.print(arena, "        {{\n            const ad = acDynAt(ix(\"{f}\"), ix(\"{f}\"), 2.0 * std.math.pi * {f}, &x, &{s}, &inst);\n", .{
            std.zig.fmtString(w.row), std.zig.fmtString(w.col), fmtF64(w.f), mdl,
        });
        const parts = [_]struct { []const u8, f64 }{ .{ "re", w.re }, .{ "im", w.im } };
        for (parts) |p| try out.print(
            arena,
            "            std.debug.print(\"acdyn[({f},{f}) f={f}].{s} got={{e}} want={{e}} ok={{d}}\\n\", .{{ ad.{s}, @as(f64, {f}), @intFromBool(@abs(ad.{s} - {f}) <= {f}) }});\n",
            .{ std.zig.fmtString(w.row), std.zig.fmtString(w.col), fmtF64(w.f), p[0], p[0], fmtF64(p[1]), p[0], fmtF64(p[1]), fmtF64(w.tol) },
        );
        try out.appendSlice(arena, "        }\n");
    }
}

/// Emits the `//! qsite` check (`tb.Directives.qsites`), once before the
/// points: the site layout is a comptime property of the device.
fn emitQSites(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §5.6.1.2 the charge sites a host tapes one by one: which rows
        \\    // each stamps (`q_stamps`) and whether `q_lte` checks it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (d.qsites) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e)});
    try out.appendSlice(arena,
        \\        };
        \\        const nq = if (comptime @hasDecl(D, "q")) contract.nQ(D) else 0;
        \\        std.debug.print("qsite count got={d} want={d} ok={d}\n", .{ nq, want.len, @intFromBool(nq == want.len) });
        \\        if (comptime @hasDecl(D, "q")) {
        \\            inline for (0..nq) |k| {
        \\                // Built at comptime from comptime stamps, so a site with
        \\                // many rows is never cut short.
        \\                const got = comptime blk: {
        \\                    @setEvalBranchQuota(1_000_000);
        \\                    var s: []const u8 = "";
        \\                    for (contract.qStamps(D)) |e| if (e.site == k) {
        \\                        s = s ++ if (e.sign == 1) @tagName(e.row) ++ "+ " else if (e.sign == -1) @tagName(e.row) ++ "- " else std.fmt.comptimePrint("{s}*{d} ", .{ @tagName(e.row), e.sign });
        \\                    };
        \\                    break :blk s ++ if (contract.qLte(D)[k]) "lte" else "nolte";
        \\                };
        \\                const w_k: []const u8 = if (k < want.len) want[k] else "<none>";
        \\                std.debug.print("qsite[{d}] got={s} want={s} ok={d}\n", .{ k, got, w_k, @intFromBool(std.mem.eql(u8, got, w_k)) });
        \\            }
        \\        }
        \\    }
        \\
    );
}

/// Emits the `//! seed` check (`tb.Directives.seeds`), once after `setup`,
/// where a host calls `seed` before solving.
fn emitSeedCheck(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §9.17.3 the cold start a host writes into its limited image.
        \\    {
        \\        const got: [n_u]?f64 = if (comptime @hasDecl(D, "seed")) D.seed(Val, &model, &inst, sim_state) else @splat(null);
        \\
    );
    // `//! seed none` writes no lane, and a `var` nothing writes is an
    // AstGen error ("never mutated").
    try out.print(arena, "        {s} want: [n_u]?f64 = @splat(null);\n", .{if (d.seeds.len == 0) "const" else "var"});
    for (d.seeds) |b| try out.print(arena, "        want[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    try out.appendSlice(arena,
        \\        const writes: u64 = if (comptime @hasDecl(D, "limit_writes")) D.limit_writes else 0;
        \\        for (got, want, 0..) |g, w, i| {
        \\            if (g == null and w == null) continue;
        \\            const ok = g != null and w != null and near(g.?, w.?);
        \\            std.debug.print("seed[{s}] got={?d} want={?d} ok={d}\n", .{ @tagName(@as(D.U, @fromBackingInt(@intCast(i)))), g, w, @intFromBool(ok) });
        \\            if (g != null) std.debug.print("seed[{s}] in limit_writes ok={d}\n", .{
        \\                @tagName(@as(D.U, @fromBackingInt(@intCast(i)))), @intFromBool(i < 64 and (writes >> @intCast(i)) & 1 != 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Emits the `//! limit` checks (`tb.Directives.limits`) at the first point,
/// after the solve, so `x` is the bias the fixture states.
fn emitLimitCheck(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    for (d.limits, 0..) |c, k| {
        try out.appendSlice(arena, "        {\n            var old = x;\n            _ = &old;\n");
        for (c.old) |b| try out.print(arena, "            old[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        try out.print(arena,
            \\            if (comptime !@hasDecl(D, "limit")) {{
            \\                std.debug.print("limit[{d}] got=none want=limit ok=0\n", .{{}});
            \\            }} else {{
            \\                const r = D.limit(Val, &{s}, &inst, x, old, sim_state);
            \\
        , .{ k, mdl });
        for (c.want) |b| {
            if (std.mem.eql(u8, b.name, "converged")) {
                try out.print(arena, "                std.debug.print(\"limit[{d}].converged got={{d}} want={d} ok={{d}}\\n\", .{{ @intFromBool(r.converged), @intFromBool(r.converged == {}) }});\n", .{ k, @intFromBool(b.value != 0), b.value != 0 });
            } else {
                try out.print(arena, "                std.debug.print(\"limit[{d}].{f} got={{d}} want={{d}} ok={{d}}\\n\", .{{ r.x[ix(\"{f}\")], @as(f64, {f}), @intFromBool(near(r.x[ix(\"{f}\")], {f})) }});\n", .{
                    k, std.zig.fmtString(b.name), std.zig.fmtString(b.name), fmtF64(b.value), std.zig.fmtString(b.name), fmtF64(b.value),
                });
            }
        }
        try out.appendSlice(arena, "            }\n        }\n");
    }
}

/// Returns the cartesian product of `sweeps` then `psweeps`, last varying
/// fastest, allocated in `arena`. Each point holds the unknown columns, then
/// the parameter columns. Fails with `error.TooManyPoints` past `max_points`.
pub fn expand(arena: Allocator, d: Directives) Error![]const []const f64 {
    const dims = d.sweeps.len + d.psweeps.len;
    if (dims == 0) return &.{&.{}};
    const col = struct {
        fn at(dd: Directives, k: usize) Sweep {
            return if (k < dd.sweeps.len) dd.sweeps[k] else dd.psweeps[k - dd.sweeps.len];
        }
    };
    var total: usize = 1;
    for (0..dims) |k| {
        total *|= col.at(d, k).values.len;
        if (total > max_points) return error.TooManyPoints;
    }
    // One block of `total * dims` cells; each row is a view into it.
    const rows = try arena.alloc([]const f64, total);
    const cells = try arena.alloc(f64, total * dims);
    for (rows, 0..) |*row, n| {
        const row_cells = cells[n * dims ..][0..dims];
        var rem = n;
        var k = dims;
        while (k > 0) {
            k -= 1;
            const vals = col.at(d, k).values;
            assert(vals.len != 0); // `parseNumbers` refuses an empty list.
            row_cells[k] = vals[rem % vals.len];
            rem /= vals.len;
        }
        // `n < total`, the product of the lengths, so every digit was used.
        assert(rem == 0);
        row.* = row_cells;
    }
    assert(rows.len == total);
    assert(total <= max_points);
    return rows;
}

/// Formats `x` as a Zig expression that evaluates to the same f64, bit for
/// bit, wherever an f64 is expected: a shortest round-trip literal, or a
/// `std.math` call for inf and nan, which have no literal.
fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64) {
    return .{ .data = x };
}

fn formatF64(x: f64, w: *Io.Writer) Io.Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("std.math.nan(f64)");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)");
    // `{d}` writes these as integer literals, which Zig reads as a
    // comptime_int: `-0` loses its sign, and past 2^53 the shortest digits
    // are not the double's own integer. `{e}` is a float literal.
    if (x == 0 and std.math.signbit(x)) return w.writeAll("-0.0");
    if (@abs(x) >= 0x1p53) return w.print("{e}", .{x});
    try w.print("{d}", .{x});
}

test fmtF64 {
    // The oracle is Zig's own reading of the text. `parseNumberLiteral`
    // classifies it as the tokenizer does: a float literal is rounded
    // correctly (`parseFloat`), but an integer literal is a comptime_int,
    // which an f64 holds exactly only when the double is that integer, and
    // which has no negative zero.
    const edge = [_]f64{
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        2.5e-3,
        300.15,
        1e20,
        0x1p53,
        0x1p53 + 2.0,
        1e23,
        -1e23,
        std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64),
        -std.math.floatTrueMin(f64),
    };
    for (edge) |x| try expectExactLiteral(x);
    var prng = std.Random.DefaultPrng.init(0x5eed_f64);
    const r = prng.random();
    for (0..4096) |_| {
        const x: f64 = @bitCast(r.int(u64));
        if (!std.math.isFinite(x)) continue;
        try expectExactLiteral(x);
    }
    // inf and nan have no literal.
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("std.math.nan(f64)", try std.mem.print(&buf, "{f}", .{fmtF64(std.math.nan(f64))}));
    try std.testing.expectEqualStrings("-std.math.inf(f64)", try std.mem.print(&buf, "{f}", .{fmtF64(-std.math.inf(f64))}));
}

/// Asserts that `fmtF64(x)` is a literal Zig reads back as `x`, bit for bit.
fn expectExactLiteral(x: f64) !void {
    var buf: [512]u8 = undefined;
    const text = try std.mem.print(&buf, "{f}", .{fmtF64(x)});
    errdefer std.debug.print("fmtF64({e}) = {s}\n", .{ x, text });
    const digits = if (text[0] == '-') text[1..] else text;
    switch (std.zig.parseNumberLiteral(digits)) {
        .float => {},
        .int => |v| {
            try std.testing.expect(!(x == 0 and std.math.signbit(x)));
            const nearest: f64 = @floatFromInt(v);
            try std.testing.expect(nearest < 0x1p64 and @as(u64, @intFromFloat(nearest)) == v);
        },
        .big_int, .failure => return error.TestUnexpectedResult,
    }
    const back = try std.fmt.parseFloat(f64, text);
    try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(back)));
}
