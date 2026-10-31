//! The descriptor: a VerA device type `D` and its module name in, the one
//! `OsdiDescriptor` a simulator reads out: its nodes, Jacobian entries,
//! collapsible pairs, noise sources and parameters (from `tables.zig`), the
//! offsets into the instance blob (`blobs.zig`), and the callbacks
//! (`params.zig`, `setup.zig`, `eval.zig`, `load.zig`). Under a split build
//! the callbacks the simulator calls every iterate are named by hidden
//! symbol instead, which the `.eval` and `.state` objects export.
//!
//! Cites OpenVAF-Reloaded `osdi_0_4.h` (every field) and `load.rs`, ngspice-45
//! `osdiregistry.c` and `osdisetup.c` (what it reads of the 0.3 prefix), and
//! LRM §3.4 (the parameter list), §6.3.6 (`$mfactor`), §4.6.4 (noise
//! source names).
//!
//! Contents:
//! - `pub fn Library(comptime D: type, comptime name: []const u8, comptime split: bool) type`
//! - `pub const Library(...).calls_setup, .mutable_eval, .iteration_hooks, .noise_table_points, .shape_check, .calls_ac_dyn: bool`
//! - `pub const Library(...).descriptors: [1]abi.Descriptor`
//! - `pub fn Library(...).exportHot(comptime part: contract.DevicePart) void`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const abi = @import("abi.zig");
const blobs = @import("blobs.zig");
const eval = @import("eval.zig");
const load = @import("load.zig");
const params = @import("params.zig");
const setup = @import("setup.zig");
const tables = @import("tables.zig");
const fixture = @import("fixture.zig"); // Tests only.
const testing = std.testing;
const no_paras = fixture.no_paras;
const real = fixture.real;
const evalDc = fixture.evalDc;

/// The OSDI library of device `D`, its descriptor named `name`. Under
/// `split` the descriptor names the per-iterate callbacks by symbol
/// (`exportHot`) instead of compiling them in.
// Generic over `D` (axis: the device; every device VerA emits is a case)
// and `split` (both builds exist: `exportDevice`, `exportDevicePart`).
pub fn Library(comptime D: type, comptime name: []const u8, comptime split: bool) type {
    const T = tables.Tables(D);
    const I = blobs.Instance(D);
    const E = eval.Eval(D);
    const L = load.Load(D);
    return struct {
        // `contract.validateHost`'s obligations, each met by the files above.
        /// `setup_model`/`setup_instance` call `setup` and `setupInstance`.
        pub const calls_setup = true;
        /// Each instance owns its `Instance` exclusively.
        pub const mutable_eval = true;
        /// `eval` calls `advanceIteration` and `checkConvergence`.
        pub const iteration_hooks = true;
        /// `load_noise` reads a table through `contract.noiseTable`.
        pub const noise_table_points = true;
        /// `derive` calls `checkShape`.
        pub const shape_check = true;
        /// `load_jacobian_react` adds `acDyn` under AC and noise.
        pub const calls_ac_dyn = true;

        /// `OSDI_DESCRIPTORS`: one descriptor, as `OSDI_NUM_DESCRIPTORS` says.
        /// Its offsets are into `blobs.Instance(D)`, the blob of
        /// `instance_size` bytes the simulator allocates zeroed and indexes
        /// by them.
        pub const descriptors = [1]abi.Descriptor{.{
            .name = zStr(name),
            .num_nodes = T.n,
            .num_terminals = D.num_ports,
            .nodes = &nodes,
            .num_jacobian_entries = T.nj,
            .jacobian_entries = &jacobian_entries,
            .num_collapsible = T.pairs.len,
            .collapsible = &collapsible,
            .collapsed_offset = @offsetOf(I, "collapsed"),
            .noise_sources = &noise_sources,
            .num_noise_src = T.gens.len,
            .num_params = T.num_params,
            .num_instance_params = T.num_inst_params,
            .num_opvars = 0,
            .param_opvar = &param_opvar,
            .node_mapping_offset = @offsetOf(I, "node_mapping"),
            .jacobian_ptr_resist_offset = @offsetOf(I, "jac_ptr"),
            .num_states = 0,
            .state_idx_off = @offsetOf(I, "state_idx"),
            .bound_step_offset = bound_step_offset,
            .instance_size = @sizeOf(I),
            .model_size = @sizeOf(blobs.Model(D)),
            .access = &params.Params(D).access,
            .setup_model = &setup.Setup(D).setupModel,
            .setup_instance = &setup.Setup(D).setupInstance,
            .eval = pick("eval"),
            .load_noise = pick("load_noise"),
            .load_residual_resist = pick("load_residual_resist"),
            .load_residual_react = pick("load_residual_react"),
            .load_limit_rhs_resist = pick("load_limit_rhs_resist"),
            .load_limit_rhs_react = pick("load_limit_rhs_react"),
            .load_spice_rhs_dc = pick("load_spice_rhs_dc"),
            .load_spice_rhs_tran = pick("load_spice_rhs_tran"),
            .load_jacobian_resist = pick("load_jacobian_resist"),
            .load_jacobian_react = pick("load_jacobian_react"),
            .load_jacobian_tran = pick("load_jacobian_tran"),
            .given_flag_model = &params.Params(D).givenModel,
            .given_flag_instance = &params.Params(D).givenInstance,
            .num_resistive_jacobian_entries = T.n_resist,
            .num_reactive_jacobian_entries = T.n_react,
            .write_jacobian_array_resist = pick("write_jacobian_array_resist"),
            .write_jacobian_array_react = pick("write_jacobian_array_react"),
            .num_inputs = 0,
            .inputs = null,
            .load_jacobian_with_offset_resist = null,
            .load_jacobian_with_offset_react = null,
            .unknown_nature = null,
            .residual_nature = null,
            .noise_source_type = null,
            .load_noise_params = null,
            .absdelay_count = 0,
            .absdelay_info = null,
        }};

        /// Exports the split build's per-iterate callbacks for `part`, each
        /// under the hidden symbol the `.setup` part's descriptor names:
        /// `load_noise` in `.state`, every other `hot` row in `.eval`.
        /// `.setup` exports nothing here (the root exports the descriptor).
        pub fn exportHot(comptime part: contract.DevicePart) void {
            comptime assert(split);
            switch (part) {
                .setup => {},
                .eval => inline for (hot) |h| {
                    if (comptime std.mem.eql(u8, h.slot, "load_noise")) continue;
                    @export(&@field(Hot, h.func), .{ .name = sym(h.slot), .visibility = .hidden });
                },
                .state => @export(&L.loadNoise, .{ .name = sym("load_noise"), .visibility = .hidden }),
            }
        }

        // ---- private ----

        /// Where the simulator reads the step bound: the breakpoint bound
        /// `eval` keeps, else the device's own `$bound_step` on a device
        /// with state, else none.
        const bound_step_offset: u32 = if (T.has_bp)
            @offsetOf(I, "bound")
        else if (T.State != void and @hasField(D.Instance, "bound_step"))
            @offsetOf(I, "inst") + @offsetOf(D.Instance, "bound_step")
        else
            abi.no_off;

        const nodes = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [T.n]abi.Node = undefined;
            for (&a, @typeInfo(D.U).@"enum".field_names, 0..) |*nd, f, i| {
                const flow = T.isFlow(i);
                nd.* = .{
                    .name = cName(f),
                    .units = if (flow) "A" else "V",
                    .residual_units = if (flow) "V" else "A",
                    .resist_residual_off = @offsetOf(I, "res") + 8 * i,
                    .react_residual_off = if (T.reactRow(i)) @offsetOf(I, "q") + 8 * i else abi.no_off,
                    .resist_limit_rhs_off = @offsetOf(I, "lim_res") + 8 * i,
                    .react_limit_rhs_off = if (T.reactRow(i)) @offsetOf(I, "lim_q") + 8 * i else abi.no_off,
                    .is_flow = flow,
                };
            }
            break :blk a;
        };

        const jacobian_entries = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [T.nj]abi.JacobianEntry = undefined;
            for (&a, T.entries, 0..) |*je, e, k| je.* = .{
                .nodes = .{ .node_1 = e.r, .node_2 = e.c },
                .react_ptr_off = if (e.react) @offsetOf(I, "react_ptr") + @sizeOf(?*f64) * k else abi.no_off,
                .flags = (if (e.resist) abi.jacobian_entry_resist else 0) | (if (e.react) abi.jacobian_entry_react else 0),
            };
            break :blk a;
        };

        const collapsible = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [T.pairs.len]abi.NodePair = undefined;
            for (&a, T.pairs) |*pair, p| pair.* = .{
                .node_1 = p.from,
                .node_2 = if (p.kind == .merge) p.to else abi.no_off,
            };
            break :blk a;
        };

        const noise_sources = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [T.gens.len]abi.NoiseSource = undefined;
            for (&a, T.gens, 0..) |*s, g, k| s.* = .{
                .name = if (g.name.len != 0) zStr(g.name) else std.fmt.comptimePrint("noise{d}", .{k}),
                .nodes = .{ .node_1 = g.row, .node_2 = if (g.row == g.col) abi.no_off else g.col },
            };
            break :blk a;
        };

        /// The instance side first (`inst_idx`, then `$mfactor`), then the
        /// model side, every parameter once more.
        const param_opvar = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [T.num_params]abi.ParamOpvar = undefined;
            for (T.params, 0..) |p, i| a[T.num_inst_params + i] = param(cName(p.field), paraTy(p.kind), "");
            for (T.inst_idx, 0..) |pi, k| a[k] = param(cName(T.params[pi].field), paraTy(T.params[pi].kind) | abi.para_kind_inst, "");
            if (T.has_mf) a[T.ni] = param("$mfactor", abi.para_ty_real | abi.para_kind_inst, "multiplicity");
            break :blk a;
        };

        /// One `hot` row: a descriptor slot and the callback behind it.
        const HotSlot = struct { slot: []const u8, func: []const u8 };
        /// The callbacks the simulator calls every iterate: the slots a split
        /// build names by symbol. `load_noise` lives in the `.state` object,
        /// every other one in `.eval`.
        const hot = [_]HotSlot{
            .{ .slot = "eval", .func = "eval" },
            .{ .slot = "load_residual_resist", .func = "loadResidualResist" },
            .{ .slot = "load_residual_react", .func = "loadResidualReact" },
            .{ .slot = "load_limit_rhs_resist", .func = "loadLimitRhsResist" },
            .{ .slot = "load_limit_rhs_react", .func = "loadLimitRhsReact" },
            .{ .slot = "load_spice_rhs_dc", .func = "loadSpiceRhsDc" },
            .{ .slot = "load_spice_rhs_tran", .func = "loadSpiceRhsTran" },
            .{ .slot = "load_jacobian_resist", .func = "loadJacobianResist" },
            .{ .slot = "load_jacobian_react", .func = "loadJacobianReact" },
            .{ .slot = "load_jacobian_tran", .func = "loadJacobianTran" },
            .{ .slot = "write_jacobian_array_resist", .func = "writeJacobianResist" },
            .{ .slot = "write_jacobian_array_react", .func = "writeJacobianReact" },
            .{ .slot = "load_noise", .func = "loadNoise" },
        };
        /// Every `hot` function, by name: `eval` and the stamps.
        const Hot = struct {
            const eval = E.eval;
            const loadResidualResist = L.loadResidualResist;
            const loadResidualReact = L.loadResidualReact;
            const loadLimitRhsResist = L.loadLimitRhsResist;
            const loadLimitRhsReact = L.loadLimitRhsReact;
            const loadSpiceRhsDc = L.loadSpiceRhsDc;
            const loadSpiceRhsTran = L.loadSpiceRhsTran;
            const loadJacobianResist = L.loadJacobianResist;
            const loadJacobianReact = L.loadJacobianReact;
            const loadJacobianTran = L.loadJacobianTran;
            const writeJacobianResist = L.writeJacobianResist;
            const writeJacobianReact = L.writeJacobianReact;
            const loadNoise = L.loadNoise;
        };

        comptime {
            assert(T.pairs.len == collapsible.len);
        }

        fn paraTy(comptime k: T.Kind) u32 {
            return switch (k) {
                .real => abi.para_ty_real,
                .int => abi.para_ty_int,
                .str => abi.para_ty_str,
            };
        }

        /// Descriptor slot `slot` (a `hot` row): the function itself, or
        /// under `split` its symbol in another object.
        fn pick(comptime slot: []const u8) @FieldType(abi.Descriptor, slot) {
            const f = inline for (hot) |h| {
                if (comptime std.mem.eql(u8, h.slot, slot)) break &@field(Hot, h.func);
            } else @compileError("not a hot slot: " ++ slot);
            return if (split) @extern(@TypeOf(f), .{ .name = sym(slot), .visibility = .hidden }) else f;
        }

        /// The hidden symbol a split build exports descriptor slot `slot`
        /// under: the device name hashed, as a name may hold any byte.
        fn sym(comptime slot: []const u8) []const u8 {
            return std.fmt.comptimePrint("vera_osdi_{s}_{x}", .{ slot, std.hash.Wyhash.hash(0, name) });
        }
    };
}

// ---- private ----

/// One parameter's `ParamOpvar` row, no alias, no units.
fn param(comptime field: [:0]const u8, comptime flags: u32, comptime description: [:0]const u8) abi.ParamOpvar {
    const names: []const abi.Str = &.{field};
    return .{ .name = names.ptr, .num_alias = 0, .description = description, .units = "", .flags = flags, .len = 0 };
}

/// A source name as written, NUL-terminated: the module name a `.model` card
/// names and a noise generator's label are not sanitized identifiers, so
/// `cName` would misread a `Z` in them as an escape.
fn zStr(comptime s: []const u8) [:0]const u8 {
    // Built in a comptime block and returned outside it, so a run-time call
    // (a test) gets the comptime constant too.
    const z = comptime s ++ [_]u8{0};
    return z[0..s.len :0];
}

/// `s` as a C string, VerA's identifier escape undone (`naming.sanitize`:
/// `Z<hex><hex>` is one byte, a trailing lone `Z` marks a Zig keyword).
fn cName(comptime s: []const u8) [:0]const u8 {
    // Computed in a comptime block and returned outside it, as `zStr`.
    const z = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        var i = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == 'Z' and i + 3 <= s.len) {
                out = out ++ [_]u8{std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable}; // VerA escapes only as two hex digits.
                i += 2;
            } else if (s[i] != 'Z') out = out ++ [_]u8{s[i]};
        }
        assert(out.len <= s.len);
        break :blk out ++ [_]u8{0};
    };
    return z[0 .. z.len - 1 :0];
}

/// A zeroed model and instance blob of device `D`, as ngspice allocates
/// them, its nodes mapped to `0 .. n`.
fn Blobs(comptime D: type) type {
    return struct {
        model: blobs.Model(D),
        inst: blobs.Instance(D),

        fn init() @This() {
            var b: @This() = .{ .model = std.mem.zeroes(blobs.Model(D)), .inst = std.mem.zeroes(blobs.Instance(D)) };
            for (&b.inst.node_mapping, 0..) |*k, i| k.* = @intCast(i);
            return b;
        }
    };
}

test "cName undoes naming.sanitize's escape" {
    try std.testing.expectEqualStrings("vth", cName("vth"));
    try std.testing.expectEqualStrings("a_b", cName("aZ5Fb")); // `_` (0x5f) escaped
    try std.testing.expectEqualStrings("pub", cName("pubZ")); // the keyword marker
    try std.testing.expectEqualStrings("Z", cName("Z5A")); // a source `Z`
}

// The descriptor driven as ngspice's osdi*.c drive it, over `fixture.zig`'s
// devices. Each expected value is derived by hand from the device's
// equations, or is a second path through the same OSDI contract.

test "the descriptor: two terminals, four dense entries, each parameter as instance and model" {
    const d = &Library(fixture.Rc, "rc", false).descriptors[0];
    try testing.expectEqualStrings("rc", std.mem.span(d.name.?));
    try testing.expectEqual(@as(u32, 2), d.num_nodes);
    try testing.expectEqual(@as(u32, 2), d.num_terminals);
    // No pattern declared: (a,a) (a,b) (b,a) (b,b), each resistive and reactive.
    try testing.expectEqual(@as(u32, 4), d.num_jacobian_entries);
    try testing.expectEqual(@as(u32, 4), d.num_resistive_jacobian_entries);
    try testing.expectEqual(@as(u32, 4), d.num_reactive_jacobian_entries);
    // `r` and `c` (not `temperature__`), each twice, plus `$mfactor`.
    try testing.expectEqual(@as(u32, 5), d.num_params);
    try testing.expectEqual(@as(u32, 3), d.num_instance_params);
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[0].name[0].?));
    try testing.expectEqual(abi.para_ty_real | abi.para_kind_inst, d.param_opvar[0].flags);
    try testing.expectEqualStrings("$mfactor", std.mem.span(d.param_opvar[2].name[0].?));
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[3].name[0].?));
    try testing.expectEqual(abi.para_ty_real, d.param_opvar[3].flags);
    try testing.expectEqualStrings("a", std.mem.span(d.nodes[0].name.?));
    try testing.expect(!d.nodes[1].is_flow);
    try testing.expectEqual(@as(u32, 0), d.num_noise_src);
    try testing.expectEqual(@as(u32, 0), d.num_collapsible);
}

test "setup, eval and every load: the stamps of a linear RC, and $mfactor over its KCL rows" {
    const d = &Library(fixture.Rc, "rc", false).descriptors[0];
    var b: Blobs(fixture.Rc) = .init();
    var info: abi.InitInfo = undefined;
    // The card sets r = 2k (model-side id: after the 3 instance parameters).
    real(d, null, &b.model, 3, abi.access_flag_set).* = 2e3;
    d.setup_model(null, &b.model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // `c` was not given: its slot reads back the default.
    try testing.expectEqual(@as(f64, 1e-12), real(d, null, &b.model, 4, 0).*);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);

    const g: f64 = 1.0 / 2e3;
    const c: f64 = 1e-12;
    try testing.expectEqual(@as(u32, 0), evalDc(d, &b.inst, &b.model, &.{ 1, 0 }));
    var res: [2]f64 = @splat(0);
    d.load_residual_resist(&b.inst, &b.model, &res);
    try testing.expectEqualSlices(f64, &.{ g, -g }, &res);
    var react: [2]f64 = @splat(0);
    d.load_residual_react(&b.inst, &b.model, &react);
    try testing.expectEqualSlices(f64, &.{ c, -c }, &react);
    // A linear device's SPICE right-hand side J·x − f is 0 at every x.
    var rhs: [2]f64 = @splat(0);
    d.load_spice_rhs_dc(&b.inst, &b.model, &rhs, undefined);
    try testing.expectEqualSlices(f64, &.{ 0, 0 }, &rhs);

    var mat: [4]f64 = @splat(0);
    var mat_q: [4]f64 = @splat(0);
    b.inst.jac_ptr = .{ &mat[0], &mat[1], &mat[2], &mat[3] };
    b.inst.react_ptr = .{ &mat_q[0], &mat_q[1], &mat_q[2], &mat_q[3] };
    d.load_jacobian_resist(&b.inst, &b.model);
    try testing.expectEqualSlices(f64, &.{ g, -g, -g, g }, &mat);
    d.load_jacobian_react(&b.inst, &b.model, 2);
    try testing.expectEqualSlices(f64, &.{ 2 * c, -2 * c, -2 * c, 2 * c }, &mat_q);
    var arr: [4]f64 = undefined;
    d.write_jacobian_array_react(&b.inst, &b.model, &arr);
    try testing.expectEqualSlices(f64, &.{ c, -c, -c, c }, &arr);
    // A transient's companion matrix: G + alpha·C into the resistive slots.
    mat = @splat(0);
    d.load_jacobian_tran(&b.inst, &b.model, 1e9);
    try testing.expectEqualSlices(f64, &.{ g + 1e9 * c, -g - 1e9 * c, -g - 1e9 * c, g + 1e9 * c }, &mat);

    // §6.3.6: $mfactor = 2 doubles every KCL row, value and Jacobian.
    real(d, &b.inst, &b.model, 2, abi.access_flag_set | abi.access_flag_instance).* = 2;
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0 });
    try testing.expectEqual(2 * g, b.inst.res[0]);
    try testing.expectEqual(2 * c, b.inst.q[0]);
    try testing.expectEqual(-2 * g, b.inst.jac[1]);
    // An instance's own r overrides the card's; the card keeps its own.
    real(d, &b.inst, &b.model, 0, abi.access_flag_set | abi.access_flag_instance).* = 4e3;
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0 });
    try testing.expectEqual(@as(f64, 1.0 / 4e3) * 2, b.inst.res[0]);
    try testing.expectEqual(@as(f64, 2e3), b.model.card.r);

    try testing.expectEqual(@as(u32, 1), d.given_flag_model(&b.model, 3)); // r, on the card
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&b.model, 4)); // c
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&b.model, 0)); // an instance id
    try testing.expectEqual(@as(u32, 1), d.given_flag_instance(&b.inst, 0));
    try testing.expectEqual(@as(u32, 1), d.given_flag_instance(&b.inst, 2)); // $mfactor
    try testing.expectEqual(@as(u32, 0), d.given_flag_instance(&b.inst, 1));
    // Past the table: no slot, and no given flag.
    try testing.expect(d.access(&b.inst, &b.model, 5, 0) == null);
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&b.model, 5));
    try testing.expectEqual(@as(u32, 0), d.given_flag_instance(&b.inst, 5));
}

test "a module with no parameters builds: $mfactor is the only slot, the model side has none (#79)" {
    const d = &Library(fixture.NoParam, "noparam", false).descriptors[0];
    try testing.expectEqual(@as(u32, 1), d.num_params);
    try testing.expectEqual(@as(u32, 1), d.num_instance_params);
    try testing.expectEqualStrings("$mfactor", std.mem.span(d.param_opvar[0].name[0].?));
    var b: Blobs(fixture.NoParam) = .init();
    var info: abi.InitInfo = undefined;
    d.setup_model(null, &b.model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // Id 0 is $mfactor on the instance; asked of the model, nothing.
    real(d, &b.inst, &b.model, 0, abi.access_flag_set | abi.access_flag_instance).* = 2;
    try testing.expect(d.access(null, &b.model, 0, 0) == null);
    try testing.expect(d.access(null, &b.model, 1, 0) == null);
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&b.model, 0));
    try testing.expectEqual(@as(u32, 1), d.given_flag_instance(&b.inst, 0));
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // 1 mS between the ports, twice under $mfactor = 2 (§6.3.6).
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0 });
    try testing.expectEqual(@as(f64, 2e-3), b.inst.res[0]);
}

test "noise: one source per generator row, its PSD coeff²·white at the last evaluated point" {
    const d = &Library(fixture.Gn, "gn", false).descriptors[0];
    try testing.expectEqual(@as(u32, 1), d.num_noise_src);
    try testing.expectEqual(@as(u32, 0), d.noise_sources.?[0].nodes.node_1);
    try testing.expectEqual(@as(u32, 1), d.noise_sources.?[0].nodes.node_2);
    var b: Blobs(fixture.Gn) = .init();
    var info: abi.InitInfo = undefined;
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0 });
    var dens: [1]f64 = undefined;
    d.load_noise(&b.inst, &b.model, 1e3, &dens);
    try testing.expectEqual(4 * 1.380649e-23 * @as(f64, 300.15) / 1e3, dens[0]);
}

test "a static request is one more iterate (LIM); breakpoints bound the step after each point" {
    const d = &Library(fixture.Ev, "ev", false).descriptors[0];
    try testing.expectEqual(@as(u32, @offsetOf(blobs.Instance(fixture.Ev), "bound")), d.bound_step_offset);
    var b: Blobs(fixture.Ev) = .init();
    var info: abi.InitInfo = undefined;
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    // DC: the first accepted iterate moved the state, so it is not converged.
    try testing.expectEqual(abi.eval_ret_flag_lim, evalDc(d, &b.inst, &b.model, &.{ 1, 0 }));
    try testing.expectEqual(@as(u32, 0), evalDc(d, &b.inst, &b.model, &.{ 1, 0 }));
    try testing.expectEqual(std.math.inf(f64), b.inst.bound);

    const tran = abi.analysis_tran | abi.calc_react_residual;
    // At 1 s the next event is 5 s: the step after is at most 4 s.
    _ = fixture.evalFlags(d, &b.inst, &b.model, &.{ 1, 0 }, 1, tran);
    try testing.expectEqual(@as(f64, 4), b.inst.bound);
    // At 5 s the event is due and runs only once 5 s is accepted: the step
    // after is held to this one's, 4 s.
    _ = fixture.evalFlags(d, &b.inst, &b.model, &.{ 1, 0 }, 5, tran);
    try testing.expectEqual(@as(f64, 4), b.inst.bound);
    // At 7 s, 5 s was accepted and scheduled 10 s: the bound is 10 - 7.
    _ = fixture.evalFlags(d, &b.inst, &b.model, &.{ 1, 0 }, 7, tran);
    try testing.expectEqual(@as(f64, 10), b.inst.inst.next);
    try testing.expectEqual(@as(f64, 3), b.inst.bound);
}

test "a $simparam list with no NULL within max_sim_paras is refused fatal; one at the cap is read" {
    const d = &Library(fixture.Rc, "rc", false).descriptors[0];
    var b: Blobs(fixture.Rc) = .init();
    var info: abi.InitInfo = undefined;
    const cap = tables.max_sim_paras;
    // cap + 1 names, then the NULL: one past the cap. (Terminated, so an
    // unbounded walk would read it all and set no flag.)
    var names: [cap + 2]abi.Str = @splat("x");
    names[cap + 1] = null;
    const vals: [cap + 1]f64 = @splat(0);
    const long: abi.SimParas = .{ .names = &names, .vals = &vals, .names_str = null, .vals_str = null };
    d.setup_model(null, &b.model, &long, &info);
    try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &long, &info);
    try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    const x = [2]f64{ 1, 0 };
    var si: abi.SimInfo = .{ .paras = long, .abstime = 0, .prev_solve = &x, .prev_state = null, .next_state = null, .flags = 0 };
    try testing.expectEqual(abi.eval_ret_flag_fatal, d.eval(null, &b.inst, &b.model, &si));
    // The legal neighbour: cap names, then the NULL.
    names[cap] = null;
    d.setup_model(null, &b.model, &long, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &long, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    si.paras = long;
    try testing.expectEqual(@as(u32, 0), d.eval(null, &b.inst, &b.model, &si));
}

test "setup_instance refuses more connected terminals than the device has, fatal" {
    const d = &Library(fixture.Rc, "rc", false).descriptors[0];
    var b: Blobs(fixture.Rc) = .init();
    var info: abi.InitInfo = undefined;
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 3, &no_paras, &info);
    try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
    // The legal neighbours: every terminal, and fewer (§9.19, the rest internal).
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 1, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
}

test "a card value outside a §3.4.2 range is fatal at setup_model and setup_instance (#80)" {
    const d = &Library(fixture.Rc, "rc", false).descriptors[0];
    var b: Blobs(fixture.Rc) = .init();
    var info: abi.InitInfo = undefined;
    // r = -1 on the card (model-side id 3): outside (0:inf).
    real(d, null, &b.model, 3, abi.access_flag_set).* = -1;
    d.setup_model(null, &b.model, &no_paras, &info);
    try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
    // The legal neighbour: r = 2k on the card.
    real(d, null, &b.model, 3, abi.access_flag_set).* = 2e3;
    d.setup_model(null, &b.model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // An instance's own r is checked too: 0 is outside the open bound.
    real(d, &b.inst, &b.model, 0, abi.access_flag_set | abi.access_flag_instance).* = 0;
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
}

test "the module and noise names are the source's, not undone escapes" {
    // `Zener` and `Zth` are legal Verilog-A names. Read as VerA's
    // `Z<hex><hex>` escape, "en" and "th" are no hex pair.
    try testing.expectEqualStrings("Zener", std.mem.span(Library(fixture.Gn, "Zener", false).descriptors[0].name.?));
    try testing.expectEqualStrings("Zth", std.mem.span(Library(fixture.Gn, "gn", false).descriptors[0].noise_sources.?[0].name.?));
}

test "write_jacobian_array_*: one slot per resistive (reactive) entry, in entry order, nothing past them" {
    const d = &Library(fixture.Cg, "cg", false).descriptors[0];
    try testing.expectEqual(@as(u32, 4), d.num_jacobian_entries);
    try testing.expectEqual(@as(u32, 2), d.num_resistive_jacobian_entries);
    try testing.expectEqual(@as(u32, 4), d.num_reactive_jacobian_entries);
    var b: Blobs(fixture.Cg) = .init();
    var info: abi.InitInfo = undefined;
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0 });
    // OpenVAF's internals.md: an array of num_resistive_jacobian_entries,
    // the entries without JACOBIAN_ENTRY_RESIST left out.
    var arr: [4]f64 = @splat(-1);
    d.write_jacobian_array_resist(&b.inst, &b.model, &arr);
    try testing.expectEqualSlices(f64, &.{ 2, 3, -1, -1 }, &arr);
    d.write_jacobian_array_react(&b.inst, &b.model, &arr);
    try testing.expectEqualSlices(f64, &.{ 5, -5, -5, 5 }, &arr);
}

test "an integer parameter the field cannot hold is fatal, not a trap; the neighbour in range is read" {
    const d = &Library(fixture.Narrow, "narrow", false).descriptors[0];
    var b: Blobs(fixture.Narrow) = .init();
    var info: abi.InitInfo = undefined;
    const card: *i32 = @ptrCast(@alignCast(d.access(null, &b.model, 1, abi.access_flag_set).?));
    for ([_]i32{ -1, 256 }) |bad| {
        card.* = bad;
        d.setup_model(null, &b.model, &no_paras, &info);
        try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
    }
    card.* = 255;
    d.setup_model(null, &b.model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    const own: *i32 = @ptrCast(@alignCast(d.access(&b.inst, &b.model, 0, abi.access_flag_set | abi.access_flag_instance).?));
    own.* = -3;
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(abi.eval_ret_flag_fatal, info.flags);
    own.* = 3;
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    try testing.expectEqual(@as(u8, 3), b.inst.row.k);
}

test "a 0 V short is a merge pair and its flow collapses into ground; no entry touches the flow" {
    const d = &Library(fixture.Short, "short", false).descriptors[0];
    try testing.expectEqual(@as(u32, 2), d.num_collapsible);
    try testing.expectEqual(abi.NodePair{ .node_1 = 2, .node_2 = 0 }, d.collapsible.?[0]);
    try testing.expectEqual(abi.NodePair{ .node_1 = 3, .node_2 = abi.no_off }, d.collapsible.?[1]);
    for (d.jacobian_entries[0..d.num_jacobian_entries]) |e| {
        try testing.expect(e.nodes.node_1 != 3);
        try testing.expect(e.nodes.node_2 != 3);
    }

    var b: Blobs(fixture.Short) = .init();
    var info: abi.InitInfo = undefined;
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    const collapsed: [*]const bool = @ptrCast(@as([*]u8, @ptrCast(&b.inst)) + d.collapsed_offset);
    try testing.expect(collapsed[0] and collapsed[1]);
    // Merged, `i` is `a`: the short's stamps are gone, the resistor's stay.
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0, 1, 0 });
    try testing.expectEqualSlices(f64, &.{ 0, -1e-3, 1e-3 }, b.inst.res[0..3]);

    // A card with rs > 0 keeps both nodes; the flow still drops.
    real(d, null, &b.model, 1, abi.access_flag_set).* = 50;
    d.setup_model(null, &b.model, &no_paras, &info);
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expect(!collapsed[0] and collapsed[1]);
    _ = evalDc(d, &b.inst, &b.model, &.{ 1, 0, 0.5, 0 });
    try testing.expectEqualSlices(f64, &.{ 0.5 / 50.0, -0.5e-3, 0.5e-3 - 0.5 / 50.0 }, b.inst.res[0..3]);
}

test "instance_params: only the marked parameter is an instance parameter; its id asked of the model reads the card" {
    const d = &Library(fixture.Short, "short", false).descriptors[0];
    // `r` on the instance side; `rs` and `r` on the model side.
    try testing.expectEqual(@as(u32, 1), d.num_instance_params);
    try testing.expectEqual(@as(u32, 3), d.num_params);
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[0].name[0].?));
    try testing.expectEqual(abi.para_ty_real | abi.para_kind_inst, d.param_opvar[0].flags);
    try testing.expectEqualStrings("rs", std.mem.span(d.param_opvar[1].name[0].?));
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[2].name[0].?));

    var b: Blobs(fixture.Short) = .init();
    var info: abi.InitInfo = undefined;
    real(d, null, &b.model, 2, abi.access_flag_set).* = 2e3; // the card's r
    d.setup_model(null, &b.model, &no_paras, &info);
    try testing.expectEqual(@as(f64, 2e3), real(d, null, &b.model, 0, 0).*);
    real(d, &b.inst, &b.model, 0, abi.access_flag_set | abi.access_flag_instance).* = 4e3;
    d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(f64, 4e3), b.inst.row.r);
    try testing.expectEqual(@as(f64, 2e3), b.model.card.r);
    // Past the one instance id (no `$mfactor` here), id 1 is the model's `rs`.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&b.model.vals[0])), d.access(&b.inst, &b.model, 1, abi.access_flag_instance));
    try testing.expectEqual(@as(u32, 0), d.given_flag_instance(&b.inst, 1));
}
