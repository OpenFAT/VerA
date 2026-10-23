//! The `--dyn` host `vera --emit-osdi` builds a device under: a VerA device
//! (lib/contract.zig) in, an OSDI 0.4 shared object out, so a simulator
//! that loads OpenVAF's `.osdi` files (ngspice `pre_osdi`) loads VerA's.
//! Exports `OSDI_VERSION_MAJOR`/`MINOR`, `OSDI_NUM_DESCRIPTORS` (1),
//! `OSDI_DESCRIPTORS`, `OSDI_DESCRIPTOR_SIZE` and the `osdi_log` slot the
//! simulator fills.
//!
//! Layout and semantics: OpenVAF-Reloaded `openvaf/osdi/header/osdi_0_4.h`
//! and `openvaf/osdi/src/load.rs` at fdf2522b70f4, and ngspice-45
//! `src/osdi/` (osdiregistry.c, osdisetup.c, osdiload.c, osdinoise.c,
//! osdiparam.c), which reads the 0.3 prefix of the descriptor and steps
//! through the array by `OSDI_DESCRIPTOR_SIZE`.
//!
//! The mapping onto the contract:
//!   nodes        every unknown of `U` (ports first, so the first
//!                `num_ports` are the terminals); a `.current`/`.flow`
//!                unknown is an OSDI flow node (ngspice `CKTmkCur`)
//!   Jacobian     every (row, col) in `jac_pattern | q_pattern`, plus the
//!                `jac_const` and `ac_dyn_slots` entries
//!   params       every scalar real, integer or string `Model` field that
//!                is a §3.4 parameter (no `__` in its name), listed TWICE:
//!                as an instance parameter and as a model parameter, since
//!                the contract does not say which a parameter is. An
//!                instance value overrides the card's. `$mfactor` is an
//!                instance parameter when `Instance` has `mfactor`.
//!   eval         one `evalQ` (or `eval`) over the sparse reference family
//!                at the limited point: `seed` under ngspice's INIT_LIM,
//!                `limit` against the previous limited point under
//!                ENABLE_LIM. The residuals and Jacobian are kept in the
//!                instance; the `load_*` calls stamp them, and the RHS is
//!                linearized at the limited point (OpenVAF's lim_rhs).
//!   noise        one OSDI source per `noise_gens` row, its PSD
//!                coeff²·(white + flicker/f^ef + table) from `noisePsd` at the
//!                last evaluated point
//!   $mfactor     §6.3.6's scaling, which the device leaves to its host:
//!                KCL rows (and noise power) times `Instance.mfactor`
//!   temperature  each instance runs on its own `Model` row: the card,
//!                the instance's own parameters and `temperature__`, then
//!                `derive`, `checkShape`, `checkRange`, `setup`, `setupInstance`
//!   collapse     a 0 V short (`D.collapse`) merges its two nodes, an OSDI
//!                collapsible pair, as OpenVAF's do, and its flow unknown
//!                collapses into ground (`collapse_applied`); a flow
//!                unknown whose branch a card switches off
//!                (`<flow>__retained` = 0 after `derive`) collapses into
//!                ground too. A short kept as a flow unknown is a
//!                zero-diagonal row, which SPARSE 1.3 pivots around at
//!                about 3,500x the factor time (psp103, 51-stage ring)
//!   static request  `updateState`'s `request_reject_at` in a static solve
//!                ("iterate again", `contract.UpdateResult`) is
//!                EVAL_RET_FLAG_LIM: ngspice counts the iterate unconverged
//!   breakpoints  `pendingBreakpoint` bounds the step after each point
//!                (`bound_step_offset`, with the device's own `$bound_step`):
//!                see `boundStep`
//!
//! A `.v` design's contract device (`rt.Device`, `vera --emit-osdi design.v`)
//! takes the same mapping: its pins are the terminals, its bridge card
//! (vdd, vth, rout, ...) the parameters.
//!
//! Not mapped, each because OSDI 0.4 has no slot for it (docs/specification/Vague_Decisions.md
//! VD-102): opvars; correlated noise (`NoiseGen.source` shared by rows,
//! `PsdTerm.corr_with`): each row is an independent source, and `vera`
//! warns W1098; a transient step rejection a device asks for
//! (`request_reject_at`), which `vera` refuses (E1099) before building this;
//! the late-event query (`stateCtl(.query)`), so a crossing is never moved
//! back to a step that ends near it; a Verilog-A device's display records
//! (`say`); and acceptance itself: OSDI has no accept
//! callback, so `updateState` and `stateCtl(.commit)` run at every iterate
//! of a static solve and, in a transient, at the last point evaluated before
//! the simulator moves time forward (a rejected step retries at an earlier
//! time, so it is never committed). A `.v` device prints what a committed
//! step ran, to stderr, at those commits.
//!
//! Host-only: never imported by the device text, so the device stays
//! GPU-compilable.
//!
//! Clauses: LRM §3.4 (parameters, shape refusal), §3.4.2 (range refusal), §4.6.4 and §4.6.4.6 (noise),
//! §5.4.2 (a switched-off branch's flow collapses), §6.3.6 (`$mfactor`),
//! §9.15 (`$simparam`), §9.17.3 (limiting and seeds), §9.19
//! (`$port_connected`).

/// Turns on the contract's conformance checks (`contract.validating`) for
/// every library built under this host: the build's root is `zigbuild`'s
/// shim, which forwards this flag from `dyn`.
pub const vera_validate_contract = true;

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");

// ---------------------------------------------------------------------------
// osdi_0_4.h
// ---------------------------------------------------------------------------

const Str = ?[*:0]const u8;
const no_off = std.math.maxInt(u32);

const para_ty_real: u32 = 0;
const para_ty_int: u32 = 1;
const para_ty_str: u32 = 2;
const para_kind_inst: u32 = 1 << 30;

const access_flag_set: u32 = 1;
const access_flag_instance: u32 = 4;

const jacobian_entry_resist: u32 = 4;
const jacobian_entry_react: u32 = 8;

const calc_react_residual: u32 = 2;
const enable_lim: u32 = 256;
const init_lim: u32 = 512;
const analysis_noise: u32 = 1024;
const analysis_ac: u32 = 4096;
const analysis_tran: u32 = 8192;

const eval_ret_flag_lim: u32 = 1;
const eval_ret_flag_fatal: u32 = 2;

const log_lvl_warn: u32 = 3;
const log_lvl_err: u32 = 4;
const log_lvl_fatal: u32 = 5;

comptime {
    // osdi_0_4.h's flag words: each flag one bit, and the flags that share a
    // word disjoint (their OR is their sum), so `flags & f` tests one flag.
    for ([_]u32{ access_flag_set, access_flag_instance, jacobian_entry_resist, jacobian_entry_react, calc_react_residual, enable_lim, init_lim, analysis_noise, analysis_ac, analysis_tran, eval_ret_flag_lim, eval_ret_flag_fatal, para_kind_inst }) |f| assert(std.math.isPowerOfTwo(f));
    assert(access_flag_set & access_flag_instance == 0);
    assert(jacobian_entry_resist & jacobian_entry_react == 0);
    assert(eval_ret_flag_lim & eval_ret_flag_fatal == 0);
    assert(calc_react_residual | enable_lim | init_lim | analysis_noise | analysis_ac | analysis_tran ==
        calc_react_residual + enable_lim + init_lim + analysis_noise + analysis_ac + analysis_tran);
    // A parameter's type sits below its kind bit (`flags = ty | para_kind_inst`).
    assert(para_ty_real < para_ty_int);
    assert(para_ty_int < para_ty_str);
    assert(para_ty_str < para_kind_inst);
    assert(log_lvl_warn < log_lvl_err);
    assert(log_lvl_err < log_lvl_fatal);
}

const SimParas = extern struct {
    names: ?[*]const Str,
    vals: ?[*]const f64,
    names_str: ?[*]const Str,
    vals_str: ?[*]const Str,
};
const SimInfo = extern struct {
    paras: SimParas,
    abstime: f64,
    prev_solve: [*]const f64,
    prev_state: ?[*]f64,
    next_state: ?[*]f64,
    flags: u32,
};
const InitError = extern struct { code: u32, parameter_id: u32 };
const InitInfo = extern struct { flags: u32, num_errors: u32, errors: ?*InitError };
const NodePair = extern struct { node_1: u32, node_2: u32 };
const JacobianEntry = extern struct { nodes: NodePair, react_ptr_off: u32, flags: u32 };
const Node = extern struct {
    name: Str,
    units: Str,
    residual_units: Str,
    resist_residual_off: u32,
    react_residual_off: u32,
    resist_limit_rhs_off: u32,
    react_limit_rhs_off: u32,
    is_flow: bool,
};
const ParamOpvar = extern struct {
    name: [*]const Str,
    num_alias: u32,
    description: Str,
    units: Str,
    flags: u32,
    len: u32,
};
const NoiseSource = extern struct { name: Str, nodes: NodePair };
const NatureRef = extern struct { ref_type: u32, index: u32 };
const AbsDelayInfo = extern struct {
    input_node_1: u32,
    input_node_2: u32,
    output_node: u32,
    delay_offset: u32,
    max_delay_offset: u32,
};

const Descriptor = extern struct {
    name: Str,
    num_nodes: u32,
    num_terminals: u32,
    nodes: [*]const Node,
    num_jacobian_entries: u32,
    jacobian_entries: [*]const JacobianEntry,
    num_collapsible: u32,
    collapsible: ?[*]const NodePair,
    collapsed_offset: u32,
    noise_sources: ?[*]const NoiseSource,
    num_noise_src: u32,
    num_params: u32,
    num_instance_params: u32,
    num_opvars: u32,
    param_opvar: [*]const ParamOpvar,
    node_mapping_offset: u32,
    jacobian_ptr_resist_offset: u32,
    num_states: u32,
    state_idx_off: u32,
    bound_step_offset: u32,
    instance_size: u32,
    model_size: u32,
    access: *const fn (?*anyopaque, ?*anyopaque, u32, u32) callconv(.c) ?*anyopaque,
    setup_model: *const fn (?*anyopaque, *anyopaque, *const SimParas, *InitInfo) callconv(.c) void,
    setup_instance: *const fn (?*anyopaque, *anyopaque, *anyopaque, f64, u32, *const SimParas, *InitInfo) callconv(.c) void,
    eval: *const fn (?*anyopaque, *anyopaque, *const anyopaque, *const SimInfo) callconv(.c) u32,
    load_noise: *const fn (*anyopaque, *anyopaque, f64, [*]f64) callconv(.c) void,
    load_residual_resist: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_residual_react: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_limit_rhs_resist: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_limit_rhs_react: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_spice_rhs_dc: *const fn (*anyopaque, *anyopaque, [*]f64, [*]const f64) callconv(.c) void,
    load_spice_rhs_tran: *const fn (*anyopaque, *anyopaque, [*]f64, [*]const f64, f64) callconv(.c) void,
    load_jacobian_resist: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    load_jacobian_react: *const fn (*anyopaque, *anyopaque, f64) callconv(.c) void,
    load_jacobian_tran: *const fn (*anyopaque, *anyopaque, f64) callconv(.c) void,
    // 0.4 additions, past the 0.3 prefix ngspice-45 reads.
    given_flag_model: *const fn (*anyopaque, u32) callconv(.c) u32,
    given_flag_instance: *const fn (*anyopaque, u32) callconv(.c) u32,
    num_resistive_jacobian_entries: u32,
    num_reactive_jacobian_entries: u32,
    write_jacobian_array_resist: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    write_jacobian_array_react: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    num_inputs: u32,
    inputs: ?[*]const NodePair,
    // ponytail: the remaining 0.4 slots are null/0: no 0.4 host here calls
    // them (ngspice-45 stops at load_jacobian_tran). Fill them when one does.
    load_jacobian_with_offset_resist: ?*const fn (*anyopaque, *anyopaque, usize) callconv(.c) void,
    load_jacobian_with_offset_react: ?*const fn (*anyopaque, *anyopaque, usize) callconv(.c) void,
    unknown_nature: ?[*]const NatureRef,
    residual_nature: ?[*]const NatureRef,
    noise_source_type: ?[*]const u32,
    load_noise_params: ?*const fn (*anyopaque, *anyopaque, [*]f64, [*]f64) callconv(.c) void,
    absdelay_count: u32,
    absdelay_info: ?[*]const AbsDelayInfo,
};

comptime {
    // The C sizes osdi_0_4.h's structs have on a 64-bit target: ngspice
    // steps through the descriptor's arrays by them.
    if (@sizeOf(usize) == 8) {
        assert(@sizeOf(NodePair) == 8);
        assert(@sizeOf(JacobianEntry) == 16);
        assert(@sizeOf(InitError) == 8);
        assert(@sizeOf(NoiseSource) == 16);
        assert(@sizeOf(SimParas) == 32);
        assert(@sizeOf(Node) == 48);
    }
}

const osdi_version_major: u32 = 0;
const osdi_version_minor: u32 = 4;
const osdi_num_descriptors: u32 = 1;
const osdi_descriptor_size: u32 = @sizeOf(Descriptor);
/// ngspice writes its logger here when it loads the library (INIT_CALLBACK).
var osdi_log: ?*const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) void = null;

/// Sends `msg` and a newline to the simulator's logger at level `lvl`; does
/// nothing before the simulator installed one.
fn log(handle: ?*anyopaque, lvl: u32, msg: []const u8) void {
    // Through the exported symbol: a split build's `.eval` object has its
    // own copy of `osdi_log`, which the simulator never writes.
    const slot = if (@import("builtin").is_test) &osdi_log else @extern(*const @TypeOf(osdi_log), .{ .name = "osdi_log" });
    const f = slot.* orelse return;
    var buf: [1024]u8 = undefined;
    // Cut to what fits with the newline and the NUL rather than dropped: a
    // fatal status names its file and line first.
    const cut = msg[0..@min(msg.len, buf.len - 2)];
    const z = std.mem.printSentinel(&buf, "{s}\n", .{cut}, 0) catch unreachable;
    assert(z.len == cut.len + 1);
    assert(z.len < buf.len);
    f(handle, z.ptr, lvl);
}

/// The most `$simparam` names a host's `OsdiSimParas.names` may hold before
/// its NULL (ngspice-45 passes 10, osdiload.c): `hostParams` reads no further.
const max_sim_paras = 256;

/// Whether C string `z` is `s`, reading at most `s.len + 1` bytes of `z`
/// (its NUL ends the match at the first byte that differs).
fn eqlZ(z: [*:0]const u8, comptime s: []const u8) bool {
    for (s, 0..) |c, i| if (z[i] != c) return false;
    return z[s.len] == 0;
}

/// The `dyn` hook `vera --emit-so` calls: exports device `D` as the one
/// OSDI descriptor, named `name` (the module's name, which a `.model` card
/// names).
pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    exportDescriptor(D, name, false);
}

/// The split build's hook (`contract.DevicePart`): `.setup` holds the
/// descriptor and the once-per-instance callbacks; `.eval` the ones the
/// simulator calls every iterate (`Osdi.hot`) and `.state` `load_noise`,
/// which the descriptor reaches through hidden symbols, so the three compile
/// in parallel. `evalQ` is most of a large device's LLVM time and the noise
/// PSD a large share of the rest; nothing in `.setup` runs per iterate.
pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: contract.DevicePart) void {
    const H = OsdiAs(D, name, true);
    switch (part) {
        .setup => exportDescriptor(D, name, true),
        .eval => inline for (H.hot) |h| {
            if (comptime std.mem.eql(u8, h[0], "load_noise")) continue;
            @export(&@field(H, h[1]), .{ .name = H.sym(h[0]), .visibility = .hidden });
        },
        .state => @export(&H.loadNoise, .{ .name = H.sym("load_noise"), .visibility = .hidden }),
    }
}

/// The scalar `D.setup` runs on here, so a split build compiles each
/// `D.setup_chunks` chunk in an object of its own (`contract.SetupValue`).
pub fn SetupValue(comptime D: type) type {
    return Osdi(D, "").Val;
}

fn exportDescriptor(comptime D: type, comptime name: []const u8, comptime split: bool) void {
    const H = OsdiAs(D, name, split);
    contract.validateHost(H, D);
    @export(&osdi_version_major, .{ .name = "OSDI_VERSION_MAJOR" });
    @export(&osdi_version_minor, .{ .name = "OSDI_VERSION_MINOR" });
    @export(&osdi_num_descriptors, .{ .name = "OSDI_NUM_DESCRIPTORS" });
    @export(&osdi_descriptor_size, .{ .name = "OSDI_DESCRIPTOR_SIZE" });
    @export(&H.descriptors, .{ .name = "OSDI_DESCRIPTORS" });
    @export(&osdi_log, .{ .name = "osdi_log" });
}

/// A source name as written, NUL-terminated: the module name a `.model` card
/// names and a noise generator's label are not sanitized identifiers, so
/// `cName` would misread a `Z` in them as an escape.
fn zStr(comptime s: []const u8) [:0]const u8 {
    // Built in a comptime block and returned outside it, so a runtime call
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
                out = out ++ [_]u8{std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable};
                i += 2;
            } else if (s[i] != 'Z') out = out ++ [_]u8{s[i]};
        }
        assert(out.len <= s.len);
        break :blk out ++ [_]u8{0};
    };
    return z[0 .. z.len - 1 :0];
}

/// The OSDI 0.4 host of device `D`: its descriptor (`descriptors`) and the
/// C callbacks the descriptor names, over the `Model` and `Instance` blobs
/// the simulator allocates (`model_size`, `instance_size`) and fills through
/// `access` before `setup_model` and `setup_instance`.
fn Osdi(comptime D: type, comptime name: []const u8) type {
    return OsdiAs(D, name, false);
}

/// `Osdi`, whose descriptor under `split` names `eval` and `load_noise` by
/// symbol (`exportDevicePart`) instead of compiling them in.
fn OsdiAs(comptime D: type, comptime name: []const u8, comptime split: bool) type {
    @setEvalBranchQuota(10_000_000);
    return struct {
        const n = contract.nU(D);
        const State = if (contract.stateClass(D) == .none) void else D.State;

        // validateHost's obligations, each met below.
        pub const calls_setup = true;
        pub const mutable_eval = true;
        pub const iteration_hooks = true;
        pub const noise_table_points = true;
        pub const shape_check = true;
        pub const calls_ac_dyn = true;

        /// Whether the device names its 0 V shorts (`collapse`, and
        /// `collapse_full` for the pairs at comptime). The descriptor then
        /// lists each as an OSDI collapsible pair, ngspice merges the
        /// short's nodes as it does OpenVAF's, and the families say so
        /// (`collapse_applied`): the device drops the short's flow unknown
        /// and its stamps instead of a zero-diagonal branch row per short.
        const collapses = @hasDecl(D, "collapse") and @hasDecl(D, "collapse_full");
        /// The value-only hooks' family: no lanes.
        const Val = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .collapse_applied = collapses });
        /// `eval`'s family: unknown `u` on lane `u`.
        const Dual = contract.RefFamily(f64, &lanes, .{ .collapse_applied = collapses });
        const lanes = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [n]u8 = undefined;
            for (&a, 0..) |*l, i| l.* = i;
            break :blk a;
        };
        const has_q = @hasDecl(D, "q");

        // ---- parameters ----------------------------------------------------

        const Kind = enum { real, int, str };
        const Param = struct { field: []const u8, kind: Kind };
        /// The §3.4 parameters: `Model` fields with no `__` (VerA's own
        /// fields all carry one, and a sanitized leaf never does) other
        /// than the setup cache.
        const params: []const Param = blk: {
            @setEvalBranchQuota(10_000_000);
            var ps: []const Param = &.{};
            const s = @typeInfo(D.Model).@"struct";
            for (s.field_names, s.field_types) |f, T| {
                if (std.mem.find(u8, f, "__") != null or std.mem.eql(u8, f, "su") or std.mem.eql(u8, f, "su_ok")) continue;
                const k: Kind = switch (@typeInfo(T)) {
                    .float => .real,
                    .int => .int,
                    else => if (T == []const u8) .str else continue,
                };
                ps = ps ++ [_]Param{.{ .field = f, .kind = k }};
            }
            break :blk ps;
        };
        const np = params.len;
        /// Every parameter, as `params` indices: the model card's set.
        const all_idx: [np]u16 = blk: {
            @setEvalBranchQuota(10 * np + 1000);
            var a: [np]u16 = undefined;
            for (&a, 0..) |*x, i| x.* = i;
            break :blk a;
        };
        /// The instance parameters, as `params` indices: the ones the device
        /// marks (`instance_params`, OpenVAF's `type = "instance"`), else
        /// every one, so a device that marks none lets an instance line set
        /// any.
        const inst_idx: []const u16 = blk: {
            @setEvalBranchQuota(10_000_000);
            if (!@hasDecl(D, "instance_params")) break :blk &all_idx;
            var a: []const u16 = &.{};
            for (params, 0..) |p, i| for (D.instance_params) |f| {
                if (std.mem.eql(u8, p.field, f)) a = a ++ [_]u16{i};
            };
            break :blk a;
        };
        const ni = inst_idx.len;
        const has_mf = @hasField(D.Instance, "mfactor");
        const num_inst_params = ni + @intFromBool(has_mf);
        const num_params = num_inst_params + np;

        comptime {
            // `slot` reinterprets one `u64` as each C type a parameter takes.
            assert(@sizeOf(f64) <= @sizeOf(u64));
            assert(@sizeOf(i32) <= @sizeOf(u64));
            assert(@sizeOf(Str) <= @sizeOf(u64));
            assert(@alignOf(Str) <= @alignOf(u64));
            assert(ni <= np);
            assert(num_params == num_inst_params + np);
        }

        /// One 8-byte value slot, in OSDI's C types: double, int32, char*.
        /// ngspice writes them through `access` before setup.
        fn slot(comptime T: type, v: *u64) *T {
            return @ptrCast(@alignCast(v));
        }

        /// Writes the given parameters of `vals` into `m`. Returns the name
        /// of an integer parameter whose host value the field cannot hold
        /// (the host's `int32_t` into VerA's narrower field), with `m`
        /// partly written; null when every value was written.
        /// `vals[k]` and `given[k]` are parameter `params[idx[k]]`.
        fn overlay(m: *D.Model, comptime idx: []const u16, vals: *[idx.len]u64, given: *const [idx.len]bool) ?[]const u8 {
            @setEvalBranchQuota(10_000_000);
            inline for (idx, 0..) |pi, i| if (given[i]) {
                const p = params[pi];
                const F = @FieldType(D.Model, p.field);
                @field(m, p.field) = switch (p.kind) {
                    .real => @floatCast(slot(f64, &vals[i]).*),
                    .int => std.math.cast(F, slot(i32, &vals[i]).*) orelse return p.field,
                    .str => if (slot(Str, &vals[i]).*) |z| std.mem.span(z) else @as(F, ""),
                };
                if (@hasDecl(D.Model, "setGiven")) m.setGiven(p.field);
            };
            return null;
        }

        /// Logs `overlay`'s refusal of parameter `param`, fatal.
        fn refuseInt(handle: ?*anyopaque, param: []const u8) void {
            var buf: [512]u8 = undefined;
            const at = "vera osdi: integer parameter `";
            log(handle, log_lvl_fatal, std.mem.print(&buf, at ++ "{s}` is outside its type's range", .{param}) catch at);
        }

        /// Writes `m`'s value of every parameter not given into `vals`, so a
        /// host reading one back (ngspice `show`) sees the default.
        fn readback(m: *const D.Model, comptime idx: []const u16, vals: *[idx.len]u64, given: *const [idx.len]bool) void {
            @setEvalBranchQuota(10_000_000);
            inline for (idx, 0..) |pi, i| if (!given[i]) switch (params[pi].kind) {
                .real => slot(f64, &vals[i]).* = @field(m, params[pi].field),
                .int => slot(i32, &vals[i]).* = std.math.lossyCast(i32, @field(m, params[pi].field)),
                // ponytail: a default string is not known to be NUL-terminated.
                .str => slot(Str, &vals[i]).* = null,
            };
        }

        const host_fields = [_][2][]const u8{
            .{ "tnom", "nom_temp__" },
            .{ "gmin", "gmin__" },
            .{ "reltol", "reltol__" },
            .{ "abstol", "abstol__" },
            .{ "vntol", "vntol__" },
            .{ "sourceScaleFactor", "source_scale__" },
        };

        /// The length of the host's NULL-terminated `$simparam` names list,
        /// which OSDI does not count: an error when no NULL is among its
        /// first `max_sim_paras + 1` entries, which are all it reads.
        fn parasLen(names: [*]const Str) error{SimParasUnterminated}!usize {
            const len = for (0..max_sim_paras + 1) |i| {
                if (names[i] == null) break i;
            } else return error.SimParasUnterminated;
            assert(len <= max_sim_paras);
            return len;
        }

        /// Copies the simulator's `$simparam` values into `m`'s host fields;
        /// returns whether one changed. `names` is the host's NULL-terminated
        /// list, which OSDI does not count: one with no NULL among its first
        /// `max_sim_paras + 1` entries is refused before `m` is written, and
        /// each name is read only as far as it can match a host field.
        fn hostParams(m: *D.Model, p: SimParas) error{SimParasUnterminated}!bool {
            @setEvalBranchQuota(10_000_000);
            const names = p.names orelse return false;
            const vals = p.vals orelse return false;
            const len = try parasLen(names);
            var changed = false;
            for (names[0..len], vals[0..len]) |nm, v| {
                inline for (host_fields) |h| if (@hasField(D.Model, h[1]) and eqlZ(nm.?, h[0])) {
                    if (@field(m, h[1]) != v) changed = true;
                    @field(m, h[1]) = v;
                };
            }
            return changed;
        }

        /// `hostParams` for `eval`, which runs every iterate: each host
        /// field's position in the simulator's names list is found once per
        /// list (ngspice passes one static array, osdiload.c), and later
        /// calls compare only values. The last match wins, as in
        /// `hostParams`.
        fn hostParamsAt(self: *Instance, p: SimParas) error{SimParasUnterminated}!bool {
            @setEvalBranchQuota(10_000_000);
            const names = p.names orelse return false;
            const vals = p.vals orelse return false;
            if (self.paras_names != names) {
                self.paras_names = null;
                const len = try parasLen(names);
                inline for (host_fields, 0..) |h, j| {
                    self.paras_at[j] = no_off;
                    for (names[0..len], 0..) |nm, i| if (eqlZ(nm.?, h[0])) {
                        self.paras_at[j] = @intCast(i);
                    };
                }
                self.paras_names = names;
            }
            var changed = false;
            inline for (host_fields, 0..) |h, j| if (@hasField(D.Model, h[1])) {
                const i = self.paras_at[j];
                if (i != no_off) {
                    if (@field(self.row, h[1]) != vals[i]) changed = true;
                    @field(self.row, h[1]) = vals[i];
                }
            };
            return changed;
        }

        /// What `setup_model`, `setup_instance` and `eval` log, fatal, when
        /// `hostParams` refuses the host's list.
        const sim_paras_refusal = std.fmt.comptimePrint("vera osdi: the simulator's $simparam names list has no NULL in its first {d} entries", .{max_sim_paras + 1});

        // ---- Jacobian entries ----------------------------------------------

        const Entry = struct { r: u8, c: u8, resist: bool, react: bool };
        fn bit(row: anytype, c: usize) bool {
            return c >= @bitSizeOf(@TypeOf(row)) or (row >> @intCast(c)) & 1 != 0;
        }
        const entries: []const Entry = blk: {
            @setEvalBranchQuota(10_000_000);
            var es: []const Entry = &.{};
            for (0..n) |r| for (0..n) |c| {
                // A short's flow unknown always collapses into ground: its
                // row and column reach no matrix slot.
                if (shortFlow(r) or shortFlow(c)) continue;
                var e: Entry = .{ .r = r, .c = c, .resist = bit(if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(u64, 0), c), .react = has_q and bit(if (@hasDecl(D, "q_pattern")) D.q_pattern[r] else ~@as(u64, 0), c) };
                for (contract.jacConst(D)) |j| if (@backingInt(j.row) == r and @backingInt(j.col) == c) {
                    e.resist = e.resist or j.g != 0;
                    e.react = e.react or j.c != 0;
                };
                for (contract.acDynSlots(D)) |s| if (s == r * n + c) {
                    e.resist = true;
                    e.react = true;
                };
                if (e.resist or e.react) es = es ++ [_]Entry{e};
            };
            break :blk es;
        };
        const nj = entries.len;
        comptime {
            @setEvalBranchQuota(10_000_000);
            assert(nj <= n * n);
            for (entries) |e| {
                assert(e.r < n);
                assert(e.c < n);
                assert(e.resist or e.react);
            }
        }
        fn entryOf(comptime r: usize, comptime c: usize) usize {
            @setEvalBranchQuota(10_000_000);
            for (entries, 0..) |e, k| if (e.r == r and e.c == c) return k;
            unreachable;
        }
        fn isFlow(comptime u: usize) bool {
            return @hasDecl(D, "u_kinds") and D.u_kinds[u] != .voltage;
        }

        /// Whether unknown `u` is a 0 V short's flow, which `collapses` drops.
        fn shortFlow(comptime u: usize) bool {
            return collapses and isFlow(u) and D.collapse_full[u] != null;
        }

        /// One OSDI collapsible pair; `to` = `no_off` is ground.
        const Pair = struct {
            from: u8,
            to: u32,
            /// What collapses it in `setupInstance`:
            ///   merge      `D.collapse` resolves `from` to `to`: a 0 V
            ///              short (a chain of them) joins the two nodes
            ///   short_flow always, under `collapses`: the family drops
            ///              the short's flow unknown, row and column, in
            ///              either arm
            ///   dead_flow  `<flow>__retained` = 0: the §5.4.2 branch's
            ///              `V(...) <+` arm is not taken, and `eval`
            ///              writes neither the flow's row nor its column
            kind: enum { merge, short_flow, dead_flow },
        };
        /// The collapsible pairs. A merge is listed for every root its node
        /// can resolve to (`collapse_full` names the deepest; a card that
        /// keeps part of a chain resolves to a root in between), so exactly
        /// the pair `D.collapse` picks is set, whatever the card.
        const pairs: []const Pair = blk: {
            @setEvalBranchQuota(10_000_000);
            var ps: []const Pair = &.{};
            if (collapses) for (0..n) |u| {
                const root = D.collapse_full[u] orelse continue;
                if (isFlow(u)) continue;
                for (0..u) |r| {
                    if (!isFlow(r) and (D.collapse_full[r] orelse r) == root)
                        ps = ps ++ [_]Pair{.{ .from = u, .to = r, .kind = .merge }};
                }
            };
            for (@typeInfo(D.U).@"enum".field_names, 0..) |f, u| {
                if (shortFlow(u)) {
                    ps = ps ++ [_]Pair{.{ .from = u, .to = no_off, .kind = .short_flow }};
                } else if (@hasField(D.Model, f ++ "__retained")) {
                    ps = ps ++ [_]Pair{.{ .from = u, .to = no_off, .kind = .dead_flow }};
                }
            }
            break :blk ps;
        };
        comptime {
            @setEvalBranchQuota(10_000_000);
            assert(D.num_ports <= n);
            for (pairs) |p| {
                assert(p.from < n);
                assert(p.to == no_off or p.to < p.from);
                assert((p.kind == .merge) == (p.to != no_off));
            }
        }

        /// Whether row `i` is a KCL row: a voltage unknown's.
        fn kcl(comptime i: usize) bool {
            return !@hasDecl(D, "u_kinds") or D.u_kinds[i] == .voltage;
        }

        /// Rows `q` writes.
        fn reactRow(comptime i: usize) bool {
            @setEvalBranchQuota(10_000_000);
            return has_q and bit(if (@hasDecl(D, "q_rows")) D.q_rows else ~@as(u64, 0), i);
        }

        // ---- model and instance data ---------------------------------------

        const Model = struct {
            vals: [np]u64,
            given: [np]bool,
            /// The card: defaults, the simulator's `$simparam`s and the given
            /// parameters, before `derive`.
            card: D.Model,
        };

        const Instance = struct {
            /// The instance parameters' slots, `inst_idx` order.
            vals: [ni]u64,
            given: [ni]bool,
            mfactor: f64,
            mfactor_given: bool,
            /// This instance's own `Model` row, derived and set up.
            row: D.Model,
            inst: D.Instance,
            node_mapping: [n]u32,
            /// `hostParamsAt`'s cache: the names list it indexed, null
            /// before the first, and each host field's position in it.
            paras_names: ?[*]const Str,
            paras_at: [host_fields.len]u32,
            collapsed: [@max(pairs.len, 1)]bool,
            state_idx: [1]u32,
            jac_ptr: [nj]?*f64,
            react_ptr: [nj]?*f64,
            res: [n]f64,
            q: [n]f64,
            lim_res: [n]f64,
            lim_q: [n]f64,
            jac: [nj]f64,
            jac_q: [nj]f64,
            /// The point `eval` last evaluated at (limited), and the
            /// simulator's unlimited one.
            x: [n]f64,
            cur: [n]f64,
            have_x: bool,
            sim: contract.SimState,
            state: State,
            t_prev: f64,
            t_last: f64,
            /// The time `accept` last committed.
            t_acc: f64,
            /// The step bound ngspice's OSDItrunc reads (`bound_step_offset`)
            /// when the device schedules breakpoints: see `boundStep`.
            bound: f64,
        };

        comptime {
            // ngspice places both at max_align_t (16 bytes).
            assert(@alignOf(Model) <= 16);
            assert(@alignOf(Instance) <= 16);
        }

        fn access(ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) callconv(.c) ?*anyopaque {
            const set = flags & access_flag_set != 0;
            if (id < ni and flags & access_flag_instance != 0) {
                const self: *Instance = @ptrCast(@alignCast(ip orelse return null));
                if (set) self.given[id] = true;
                return &self.vals[id];
            }
            if (has_mf and id == ni) {
                const self: *Instance = @ptrCast(@alignCast(ip orelse return null));
                if (set) self.mfactor_given = true;
                return &self.mfactor;
            }
            // §3.4 parameters are optional (#79): with none, no model-side
            // id exists, and `given`/`vals` are zero-length arrays that a
            // runtime index may not be analysed against.
            if (np == 0) return null;
            // A model-side id, or an instance parameter asked of the model
            // (OpenVAF's semantics: the card's value of it).
            const j = if (id < ni) inst_idx[id] else if (id >= num_inst_params and id < num_params) id - num_inst_params else return null;
            const m: *Model = @ptrCast(@alignCast(mp orelse return null));
            if (set) m.given[j] = true;
            return &m.vals[j];
        }

        fn givenModel(mp: *anyopaque, id: u32) callconv(.c) u32 {
            const m: *Model = @ptrCast(@alignCast(mp));
            // No parameter, no model-side flag (`access`, #79).
            if (np == 0 or id < num_inst_params or id >= num_params) return 0;
            return @intFromBool(m.given[id - num_inst_params]);
        }

        fn givenInstance(ip: *anyopaque, id: u32) callconv(.c) u32 {
            const self = inst(ip);
            if (has_mf and id == ni) return @intFromBool(self.mfactor_given);
            return if (id < ni) @intFromBool(self.given[id]) else 0;
        }

        /// `derive`, `checkShape` and `checkRange` on `m`; false (and a fatal
        /// log) when the card moves a shape parameter or puts one outside its
        /// §3.4.2 range ("It shall be an error ... during simulation", #80).
        fn derive(handle: ?*anyopaque, m: *D.Model) bool {
            if (@hasDecl(D, "derive")) D.derive(Val, m);
            if (@hasDecl(D, "checkShape")) if (D.checkShape(m)) |why| {
                log(handle, log_lvl_fatal, why);
                return false;
            };
            if (@hasDecl(D, "checkRange")) if (D.checkRange(m)) |param| {
                var buf: [512]u8 = undefined;
                const at = "error[E0377]: LRM 3.4.2: parameter `";
                const msg = std.mem.print(&buf, at ++ "{s}` is outside its declared range", .{param}) catch at;
                log(handle, log_lvl_fatal, msg);
                return false;
            };
            if (@hasDecl(D, "checkCard")) if (D.checkCard(m)) |why| log(handle, log_lvl_err, why);
            return true;
        }

        fn setupModel(handle: ?*anyopaque, mp: *anyopaque, paras: *const SimParas, res: *InitInfo) callconv(.c) void {
            const m: *Model = @ptrCast(@alignCast(mp));
            res.* = .{ .flags = 0, .num_errors = 0, .errors = null };
            m.card = .{};
            _ = hostParams(&m.card, paras.*) catch {
                log(handle, log_lvl_fatal, sim_paras_refusal);
                res.flags |= eval_ret_flag_fatal;
                return;
            };
            if (overlay(&m.card, &all_idx, &m.vals, &m.given)) |param| {
                refuseInt(handle, param);
                res.flags |= eval_ret_flag_fatal;
                return;
            }
            var d = m.card;
            if (!derive(handle, &d)) res.flags |= eval_ret_flag_fatal;
            readback(&d, &all_idx, &m.vals, &m.given);
        }

        fn setupInstance(handle: ?*anyopaque, ip: *anyopaque, mp: *anyopaque, temperature: f64, connected: u32, paras: *const SimParas, res: *InitInfo) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            const m: *Model = @ptrCast(@alignCast(mp));
            res.* = .{ .flags = 0, .num_errors = 0, .errors = null };
            // Fallible first: both refusals return before the instance is
            // touched. ngspice passes `num_terminals` less the unconnected
            // trailing ones (osdisetup.c), never more.
            if (connected > D.num_ports) {
                var buf: [128]u8 = undefined;
                log(handle, log_lvl_fatal, std.mem.print(&buf, "vera osdi: setup_instance connects {d} terminals; the device has {d}", .{ connected, D.num_ports }) catch unreachable);
                res.flags |= eval_ret_flag_fatal;
                return;
            }
            self.row = m.card;
            _ = hostParams(&self.row, paras.*) catch {
                log(handle, log_lvl_fatal, sim_paras_refusal);
                res.flags |= eval_ret_flag_fatal;
                return;
            };
            if (overlay(&self.row, inst_idx, &self.vals, &self.given)) |param| {
                refuseInt(handle, param);
                res.flags |= eval_ret_flag_fatal;
                return;
            }
            if (@hasField(D.Model, "temperature__")) self.row.temperature__ = temperature;
            // §9.19 `$port_connected`: ngspice connects the first
            // `connected` terminals and makes the rest internal nodes.
            if (@hasField(D.Model, "port_connected__"))
                self.row.port_connected__ = if (connected >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(connected)) - 1;
            if (!derive(handle, &self.row)) res.flags |= eval_ret_flag_fatal;
            readback(&self.row, inst_idx, &self.vals, &self.given);
            if (@hasDecl(D, "setup")) D.setup(Val, &self.row);
            self.inst = .{};
            if (has_mf) {
                if (!self.mfactor_given) self.mfactor = 1;
                self.inst.mfactor = self.mfactor;
            }
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&self.row, &self.inst);
            const roots: [n]?u8 = if (collapses) D.collapse(Val, &self.row, &self.inst) else @splat(null);
            inline for (pairs, 0..) |p, k| self.collapsed[k] = switch (p.kind) {
                .merge => if (roots[p.from]) |r| r == p.to else false,
                .short_flow => true,
                .dead_flow => @field(self.row, @typeInfo(D.U).@"enum".field_names[p.from] ++ "__retained") == 0,
            };
            if (State != void) self.state = D.initState(&self.row, &self.inst);
            self.have_x = false;
            self.paras_names = null;
            self.sim = .{};
            self.t_prev = 0;
            self.t_last = 0;
            self.t_acc = 0;
            self.bound = std.math.inf(f64);
        }

        /// The analysis OSDI's flags describe (ngspice osdiload.c sets them).
        fn simState(self: *Instance, info: *const SimInfo) contract.SimState {
            const f = info.flags;
            var s: contract.SimState = .{ .t = info.abstime, .analog_initial = false };
            if (f & analysis_ac != 0) {
                s.kind = .ac;
            } else if (f & analysis_noise != 0) {
                s.kind = .noise;
            } else if (f & analysis_tran != 0 and f & calc_react_residual != 0) {
                // ponytail: OSDI passes no step, so dt is the distance to the
                // last earlier time evaluated; a rejected-and-retried step
                // sees the right one, a later retry at a time past the
                // rejected one does not.
                //
                // OSDI 0.4 promises nothing about the order of `abstime`, and
                // a host can move behind the point taken as accepted: one
                // that starts a second transient without `setup_instance`
                // (ngspice re-runs it only on a reset, cktdojob.c), or
                // ngspice's own shared-sync bug (dctran.c, "CKTtime becomes
                // less than last_accepted_time"). That time is no step from
                // `t_prev`, and `sim.dt` feeds laplace, zi, idtmod and
                // absdelay, so the history restarts as `setup_instance`
                // leaves it: the step is from 0 (or from `abstime` itself
                // if the host passes a negative time), never negative.
                if (info.abstime < self.t_prev) self.t_prev = @min(0, info.abstime);
                if (info.abstime > self.t_last) {
                    self.t_prev = self.t_last;
                    self.t_last = info.abstime;
                } else if (info.abstime < self.t_last) self.t_last = info.abstime;
                s.kind = .tran;
                s.dt = info.abstime - self.t_prev;
                assert(!(s.dt < 0)); // a NaN `abstime` is the host's, and passes through
            } else {
                // A transient's own operating point is §4.6.1's IC analysis.
                s.kind = if (f & analysis_tran != 0) .ic else .dc;
                s.initial_step = true;
                s.analog_initial = true;
            }
            return s;
        }

        fn eval(handle: ?*anyopaque, ip: *anyopaque, _: *const anyopaque, info: *const SimInfo) callconv(.c) u32 {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            var ret: u32 = 0;
            // Gmin and source stepping move a `$simparam` mid-solve.
            if (hostParamsAt(self, info.paras) catch {
                log(handle, log_lvl_fatal, sim_paras_refusal);
                return eval_ret_flag_fatal;
            }) {
                if (@hasDecl(D, "setup")) D.setup(Val, &self.row);
                if (@hasDecl(D, "setupInstance")) D.setupInstance(&self.row, &self.inst);
            }
            // The last point before the simulator moves time forward is the
            // one it accepted (a rejected step retries at an earlier time).
            if (State != void and self.have_x and self.sim.kind == .tran and info.abstime > self.sim.t and info.flags & calc_react_residual != 0) _ = accept(self);
            const sim = simState(self, info);
            if (@hasDecl(D, "advanceIteration") and self.have_x) D.advanceIteration(Val, &self.row, &self.inst, self.x, sim);

            var cur: [n]f64 = undefined;
            for (&cur, self.node_mapping) |*c, k| c.* = info.prev_solve[k];
            var x = cur;
            if (info.flags & init_lim != 0 and @hasDecl(D, "seed")) {
                // SPICE MODEINITJCT: the seeds are node values from a 0 V root.
                x = @splat(0);
                for (D.seed(Val, &self.row, &self.inst, sim), &x) |s, *xi| if (s) |v| {
                    xi.* = v;
                };
            } else if (info.flags & enable_lim != 0 and @hasDecl(D, "limit") and self.have_x) {
                const r = D.limit(Val, &self.row, &self.inst, cur, self.x, sim);
                x = r.x;
                if (!r.converged) ret |= eval_ret_flag_lim;
            }

            if (has_q) {
                const out = D.evalQ(Dual, &x, &self.row, &self.inst, sim);
                const qr = contract.qRows(D, Dual, out.q);
                inline for (0..n) |i| {
                    self.res[i] = out.res[i].val();
                    self.q[i] = qr[i].val();
                }
                inline for (entries, 0..) |e, k| {
                    self.jac[k] = out.res[e.r].ddxAt(e.c);
                    self.jac_q[k] = qr[e.r].ddxAt(e.c);
                }
            } else {
                const rows = D.eval(Dual, &x, &self.row, &self.inst, sim);
                inline for (0..n) |i| self.res[i] = rows[i].val();
                inline for (entries, 0..) |e, k| {
                    self.jac[k] = rows[e.r].ddxAt(e.c);
                    self.jac_q[k] = 0;
                }
            }
            inline for (comptime contract.jacConst(D)) |e| {
                if (comptime shortFlow(@backingInt(e.row)) or shortFlow(@backingInt(e.col))) continue;
                if (contract.jacConstApplies(D, e, &self.row, collapses)) {
                    const k = comptime entryOf(@backingInt(e.row), @backingInt(e.col));
                    self.jac[k] = e.g;
                    self.jac_q[k] = e.c;
                }
            }

            // §6.3.6: every flow contribution is multiplied by $mfactor and
            // every flow probe divided by it. The device applies neither, so
            // the KCL rows (a voltage unknown's) scale by it here; a flow
            // unknown's own row is its branch's potential equation and does
            // not, which leaves the flow unknown the per-device current the
            // probe reads.
            if (has_mf and self.inst.mfactor != 1) {
                const m = self.inst.mfactor;
                inline for (0..n) |i| if (comptime kcl(i)) {
                    self.res[i] *= m;
                    self.q[i] *= m;
                };
                inline for (entries, 0..) |e, k| if (comptime kcl(e.r)) {
                    self.jac[k] *= m;
                    self.jac_q[k] *= m;
                };
            }

            // OpenVAF's lim_rhs: J·(x_limited − x), which turns the RHS
            // J·prev_solve − f into the linearization at the limited point.
            self.lim_res = @splat(0);
            self.lim_q = @splat(0);
            // Zero unless limiting or a seed moved the point.
            if (@reduce(.Or, @as(@Vector(n, f64), x) != @as(@Vector(n, f64), cur))) {
                inline for (entries, 0..) |e, k| {
                    const dx = x[e.c] - cur[e.c];
                    self.lim_res[e.r] += self.jac[k] * dx;
                    self.lim_q[e.r] += self.jac_q[k] * dx;
                }
            }
            self.x = x;
            self.cur = cur;
            self.have_x = true;
            self.sim = sim;

            // A static solve has no steps to reject: every iterate is accepted.
            // A request there means "iterate again" (`contract.UpdateResult`):
            // the device's state moved, so this iterate is not converged.
            if (State != void and (sim.kind == .dc or sim.kind == .ic) and accept(self) != .ok) ret |= eval_ret_flag_lim;
            if (has_bp) boundStep(self, sim);
            if (@hasDecl(D, "checkConvergence") and !D.checkConvergence(Val, &self.row, &self.inst, x, sim)) ret |= eval_ret_flag_lim;
            if (@hasField(D.Instance, "vera_status__") and self.inst.vera_status__ != 0) {
                var buf: [512]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                contract.formatStatus(D, &self.inst, &w) catch {};
                log(handle, log_lvl_fatal, w.buffered());
                ret |= eval_ret_flag_fatal;
            }
            assert(ret & ~(eval_ret_flag_lim | eval_ret_flag_fatal) == 0);
            return ret;
        }

        /// `updateState` and `stateCtl(.commit)` at the last evaluated point;
        /// what `updateState` returned. Asserts that `eval` has evaluated a
        /// point to commit.
        fn accept(self: *Instance) contract.UpdateResult {
            comptime assert(State != void);
            assert(self.have_x);
            const r = D.updateState(Val, &self.row, &self.inst, self.x, &self.state, self.sim);
            if (@hasDecl(D, "stateCtl")) _ = D.stateCtl(&self.row, &self.inst, &self.state, .commit);
            self.t_acc = self.sim.t;
            return r;
        }

        const has_bp = State != void and @hasDecl(D, "pendingBreakpoint");

        /// OSDI has no breakpoint slot, so `pendingBreakpoint` becomes the
        /// step bound ngspice's OSDItrunc applies to the step after this
        /// point: the distance to the device's next breakpoint after the
        /// accepted time. One due at or before this point runs only when the
        /// point is accepted (`accept`), so what it schedules next is not
        /// known yet: the next step is held to this one's length. The device's
        /// own `$bound_step` bounds it too.
        fn boundStep(self: *Instance, sim: contract.SimState) void {
            comptime assert(has_bp);
            const inf = std.math.inf(f64);
            self.bound = if (@hasField(D.Instance, "bound_step")) self.inst.bound_step else inf;
            if (sim.kind != .tran) return;
            const bp = D.pendingBreakpoint(&self.inst, self.t_acc) orelse return;
            const b = if (bp > sim.t) bp - sim.t else sim.t - self.t_acc;
            if (b > 0) self.bound = @min(self.bound, b);
        }

        /// The simulator's instance blob as this device's `Instance`.
        fn inst(ip: *anyopaque) *Instance {
            return @ptrCast(@alignCast(ip));
        }

        fn loadResidualResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.res, self.node_mapping) |v, k| dst[k] += v;
        }
        fn loadResidualReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.q, self.node_mapping) |v, k| dst[k] += v;
        }
        fn loadLimitRhsResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.lim_res, self.node_mapping) |v, k| dst[k] -= v;
        }
        fn loadLimitRhsReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.lim_q, self.node_mapping) |v, k| dst[k] -= v;
        }

        /// SPICE's RHS: J·x − f at the limited point `x` (OpenVAF
        /// load_spice_rhs_dc: J·prev_solve − f + lim_rhs, the same sum).
        fn loadSpiceRhsDc(ip: *anyopaque, _: *anyopaque, dst: [*]f64, _: [*]const f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            var rhs: [n]f64 = undefined;
            for (&rhs, self.res) |*r, f| r.* = -f;
            inline for (entries, 0..) |e, k| rhs[e.r] += self.jac[k] * self.x[e.c];
            for (rhs, self.node_mapping) |v, k| dst[k] += v;
        }

        /// The DC RHS plus alpha·Jq·x; the simulator subtracts its own
        /// integrated dQ/dt (ngspice osdiload.c).
        fn loadSpiceRhsTran(ip: *anyopaque, mp: *anyopaque, dst: [*]f64, prev: [*]const f64, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            loadSpiceRhsDc(ip, mp, dst, prev);
            const self = inst(ip);
            var rhs: [n]f64 = @splat(0);
            inline for (entries, 0..) |e, k| rhs[e.r] += self.jac_q[k] * self.x[e.c];
            for (rhs, self.node_mapping) |v, k| dst[k] += alpha * v;
        }

        fn loadJacobianResist(ip: *anyopaque, _: *anyopaque) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (entries, 0..) |e, k| if (e.resist) {
                if (self.jac_ptr[k]) |p| p.* += self.jac[k];
            };
        }

        /// alpha·dQ/dx into the imaginary half; under AC or noise also the
        /// frequency-dependent slots `eval` left out (`acDyn`), whose real
        /// part goes to the real half and whose imaginary part already
        /// carries ω (ngspice passes alpha = ω, osdiacld.c).
        fn loadJacobianReact(ip: *anyopaque, _: *anyopaque, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (entries, 0..) |e, k| if (e.react) {
                if (self.react_ptr[k]) |p| p.* += alpha * self.jac_q[k];
            };
            if (@hasDecl(D, "acDyn") and (self.sim.kind == .ac or self.sim.kind == .noise)) {
                var out: [D.ac_dyn_slots.len]std.math.Complex(f64) = undefined;
                D.acDyn(f64, &self.row, &self.inst, &self.x, self.sim, alpha, &out);
                inline for (D.ac_dyn_slots, 0..) |s, j| {
                    if (comptime shortFlow(s / n) or shortFlow(s % n)) continue;
                    const k = comptime entryOf(s / n, s % n);
                    if (self.jac_ptr[k]) |p| p.* += out[j].re;
                    if (self.react_ptr[k]) |p| p.* += out[j].im;
                }
            }
        }

        fn loadJacobianTran(ip: *anyopaque, _: *anyopaque, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (0..nj) |k| if (self.jac_ptr[k]) |p| {
                p.* += self.jac[k] + alpha * self.jac_q[k];
            };
        }

        /// `dst` holds `n_resist` (`n_react`) doubles: the entries with the
        /// flag, in entry order (OpenVAF internals.md).
        fn writeJacobianResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            comptime var j = 0;
            inline for (entries, 0..) |e, k| if (e.resist) {
                dst[j] = self.jac[k];
                j += 1;
            };
            comptime assert(j == n_resist);
        }
        fn writeJacobianReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            comptime var j = 0;
            inline for (entries, 0..) |e, k| if (e.react) {
                dst[j] = self.jac_q[k];
                j += 1;
            };
            comptime assert(j == n_react);
        }

        // ---- noise ---------------------------------------------------------

        const gens = if (@hasDecl(D, "noise_gens")) D.noise_gens else [0]contract.NoiseGen(D){};

        /// §4.6.4.3/.4 a table generator's PSD at `f`, from the card's
        /// knots (`contract.noiseTable` on the derived row).
        fn tableAt(row: *const D.Model, comptime table: ?u16, f: f64) f64 {
            const ti = table orelse return 0;
            return contract.noiseTableAt(contract.noiseTable(D, row, ti), f);
        }

        fn loadNoise(ip: *anyopaque, _: *anyopaque, freq: f64, dens: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            if (gens.len == 0) return;
            const self = inst(ip);
            const psd = D.noisePsd(Val, self.x, &self.row, &self.inst, self.sim);
            inline for (gens, 0..) |g, k| {
                const t = psd[k];
                const shape = if (t.flicker == 0 or freq <= 0) t.white else t.white + t.flicker / std.math.pow(f64, freq, t.ef);
                // §6.3.6: a flow's noise scales with $mfactor too, in power.
                const m = if (has_mf) self.inst.mfactor else 1;
                dens[k] = m * t.coeff * t.coeff * (shape + tableAt(&self.row, g.table, freq));
            }
        }

        // ---- the descriptor ------------------------------------------------

        const nodes = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [n]Node = undefined;
            for (&a, @typeInfo(D.U).@"enum".field_names, 0..) |*nd, f, i| {
                const flow = isFlow(i);
                nd.* = .{
                    .name = cName(f),
                    .units = if (flow) "A" else "V",
                    .residual_units = if (flow) "V" else "A",
                    .resist_residual_off = @offsetOf(Instance, "res") + 8 * i,
                    .react_residual_off = if (reactRow(i)) @offsetOf(Instance, "q") + 8 * i else no_off,
                    .resist_limit_rhs_off = @offsetOf(Instance, "lim_res") + 8 * i,
                    .react_limit_rhs_off = if (reactRow(i)) @offsetOf(Instance, "lim_q") + 8 * i else no_off,
                    .is_flow = flow,
                };
            }
            break :blk a;
        };

        const jacobian_entries = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [nj]JacobianEntry = undefined;
            for (&a, entries, 0..) |*je, e, k| je.* = .{
                .nodes = .{ .node_1 = e.r, .node_2 = e.c },
                .react_ptr_off = if (e.react) @offsetOf(Instance, "react_ptr") + @sizeOf(?*f64) * k else no_off,
                .flags = (if (e.resist) jacobian_entry_resist else 0) | (if (e.react) jacobian_entry_react else 0),
            };
            break :blk a;
        };

        const collapsible = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [pairs.len]NodePair = undefined;
            for (&a, pairs) |*np_, p| np_.* = .{ .node_1 = p.from, .node_2 = p.to };
            break :blk a;
        };

        const noise_sources = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [gens.len]NoiseSource = undefined;
            for (&a, gens, 0..) |*s, g, k| s.* = .{
                .name = if (g.name.len != 0) zStr(g.name) else std.fmt.comptimePrint("noise{d}", .{k}),
                .nodes = .{ .node_1 = g.row, .node_2 = if (g.row == g.col) no_off else g.col },
            };
            for (gens) |g| {
                assert(g.row < n);
                assert(g.col < n);
            }
            break :blk a;
        };

        const param_opvar = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [num_params]ParamOpvar = undefined;
            for (params, 0..) |p, i| {
                const names: []const Str = &.{cName(p.field)};
                a[num_inst_params + i] = .{ .name = names.ptr, .num_alias = 0, .description = "", .units = "", .flags = paraTy(p.kind), .len = 0 };
            }
            for (inst_idx, 0..) |pi, k| {
                const names: []const Str = &.{cName(params[pi].field)};
                a[k] = .{ .name = names.ptr, .num_alias = 0, .description = "", .units = "", .flags = paraTy(params[pi].kind) | para_kind_inst, .len = 0 };
            }
            if (has_mf) {
                const names: []const Str = &.{"$mfactor"};
                a[ni] = .{ .name = names.ptr, .num_alias = 0, .description = "multiplicity", .units = "", .flags = para_ty_real | para_kind_inst, .len = 0 };
            }
            break :blk a;
        };

        fn paraTy(comptime k: Kind) u32 {
            return switch (k) {
                .real => para_ty_real,
                .int => para_ty_int,
                .str => para_ty_str,
            };
        }

        const n_resist = blk: {
            @setEvalBranchQuota(10_000_000);
            var c: u32 = 0;
            for (entries) |e| c += @intFromBool(e.resist);
            assert(c <= nj);
            break :blk c;
        };
        const n_react = blk: {
            @setEvalBranchQuota(10_000_000);
            var c: u32 = 0;
            for (entries) |e| c += @intFromBool(e.react);
            assert(c <= nj);
            break :blk c;
        };

        /// The descriptor slots a split build names by symbol, and the
        /// function behind each: `load_noise` in the `.state` object, every
        /// other one (the ones the simulator calls every iterate) in `.eval`.
        const hot = [_][2][]const u8{
            .{ "eval", "eval" },
            .{ "load_residual_resist", "loadResidualResist" },
            .{ "load_residual_react", "loadResidualReact" },
            .{ "load_limit_rhs_resist", "loadLimitRhsResist" },
            .{ "load_limit_rhs_react", "loadLimitRhsReact" },
            .{ "load_spice_rhs_dc", "loadSpiceRhsDc" },
            .{ "load_spice_rhs_tran", "loadSpiceRhsTran" },
            .{ "load_jacobian_resist", "loadJacobianResist" },
            .{ "load_jacobian_react", "loadJacobianReact" },
            .{ "load_jacobian_tran", "loadJacobianTran" },
            .{ "write_jacobian_array_resist", "writeJacobianResist" },
            .{ "write_jacobian_array_react", "writeJacobianReact" },
            .{ "load_noise", "loadNoise" },
        };

        /// The hidden symbol a split build exports descriptor slot `field`
        /// under: the device name hashed, as a name may hold any byte.
        fn sym(comptime field: []const u8) []const u8 {
            return std.fmt.comptimePrint("vera_osdi_{s}_{x}", .{ field, std.hash.Wyhash.hash(0, name) });
        }

        /// Descriptor slot `field` (a `hot` row): the function itself, or
        /// under `split` its symbol in another object.
        fn pick(comptime field: []const u8) @FieldType(Descriptor, field) {
            const f = inline for (hot) |h| {
                if (comptime std.mem.eql(u8, h[0], field)) break &@field(@This(), h[1]);
            } else @compileError("not a hot slot: " ++ field);
            return if (split) @extern(@TypeOf(f), .{ .name = sym(field), .visibility = .hidden }) else f;
        }

        /// `OSDI_DESCRIPTORS`: one descriptor, as `OSDI_NUM_DESCRIPTORS` says.
        /// Its offsets are into `Instance`, the blob of `instance_size` bytes
        /// the simulator allocates zeroed and indexes by them.
        pub const descriptors = [1]Descriptor{.{
            .name = zStr(name),
            .num_nodes = n,
            .num_terminals = D.num_ports,
            .nodes = &nodes,
            .num_jacobian_entries = nj,
            .jacobian_entries = &jacobian_entries,
            .num_collapsible = pairs.len,
            .collapsible = &collapsible,
            .collapsed_offset = @offsetOf(Instance, "collapsed"),
            .noise_sources = &noise_sources,
            .num_noise_src = gens.len,
            .num_params = num_params,
            .num_instance_params = num_inst_params,
            .num_opvars = 0,
            .param_opvar = &param_opvar,
            .node_mapping_offset = @offsetOf(Instance, "node_mapping"),
            .jacobian_ptr_resist_offset = @offsetOf(Instance, "jac_ptr"),
            .num_states = 0,
            .state_idx_off = @offsetOf(Instance, "state_idx"),
            .bound_step_offset = if (has_bp) @offsetOf(Instance, "bound") else if (State != void and @hasField(D.Instance, "bound_step")) @offsetOf(Instance, "inst") + @offsetOf(D.Instance, "bound_step") else no_off,
            .instance_size = @sizeOf(Instance),
            .model_size = @sizeOf(Model),
            .access = &access,
            .setup_model = &setupModel,
            .setup_instance = &setupInstance,
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
            .given_flag_model = &givenModel,
            .given_flag_instance = &givenInstance,
            .num_resistive_jacobian_entries = n_resist,
            .num_reactive_jacobian_entries = n_react,
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
    };
}

// ---------------------------------------------------------------------------
// Tests: the descriptor driven as ngspice's osdi*.c drive it, over hand-written
// linear devices whose every stamp is known exactly.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A conductance 1/r in parallel with a capacitance c between two ports, plus
/// `$mfactor`: every resistive and reactive path, and an instance parameter
/// over the card.
const Rc = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { r: f64 = 1e3, c: f64 = 1e-12, temperature__: f64 = 300.15 };
    pub const Instance = struct { mfactor: f64 = 1 };

    pub fn eval(comptime S: type, x: *const [2]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const i = p[0].sub(p[1]).scale(1.0 / m.r);
        return contract.rows(@This(), S, .{ i, i.neg() });
    }
    pub fn q(comptime S: type, x: *const [2]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Sites(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const v = p[0].sub(p[1]).scale(m.c);
        return contract.sites(@This(), S, .{ v, v.neg() });
    }
    pub fn evalQ(comptime S: type, x: *const [2]S.V, m: *const Model, i: *const Instance, sim: contract.SimState) struct { res: contract.Rows(Rc, S), q: contract.Sites(Rc, S) } {
        return .{ .res = eval(S, x, m, i, sim), .q = q(S, x, m, i, sim) };
    }
    /// `parameter real r = 1k from (0:inf);`, as VerA emits it (§3.4.2).
    pub fn checkRange(m: *const Model) ?[]const u8 {
        return if (!(m.r > 0.0 and m.r < std.math.inf(f64))) "r" else null;
    }
};

/// A conductance with one named thermal generator across it.
const Gn = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { r: f64 = 1e3, temperature__: f64 = 300.15 };
    pub const Instance = struct {};
    pub const noise_gens = [_]contract.NoiseGen(@This()){.{ .row = 0, .col = 1, .kind = .thermal, .name = "Zth" }};

    pub fn eval(comptime S: type, x: *const [2]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const i = p[0].sub(p[1]).scale(1.0 / m.r);
        return contract.rows(@This(), S, .{ i, i.neg() });
    }
    pub fn noisePsd(comptime _: type, _: [2]f64, m: *const Model, _: *const Instance, _: contract.SimState) [1]contract.PsdTerm {
        return .{.{ .white = 4 * 1.380649e-23 * m.temperature__ / m.r }};
    }
};

/// A conductance with digital-style state: an event every 5 s from 5 s
/// (`pendingBreakpoint`), and a static solve whose first accepted iterate
/// moves its state (`request_reject_at`, "iterate again").
const Ev = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct {};
    pub const Instance = struct { next: f64 = 5, settled: bool = false };
    pub const State = struct {};
    pub const state_class: contract.StateClass = .history;

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const i = p[0].sub(p[1]);
        return contract.rows(@This(), S, .{ i, i.neg() });
    }
    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }
    pub fn updateState(comptime _: type, _: *const Model, inst: *Instance, _: [2]f64, _: *State, sim: contract.SimState) contract.UpdateResult {
        if (sim.kind != .tran) {
            if (inst.settled) return .ok;
            inst.settled = true;
            return .{ .request_reject_at = sim.t };
        }
        while (inst.next <= sim.t) inst.next += 5;
        return .ok;
    }
    pub fn stateCtl(_: *const Model, _: *Instance, _: *State, _: contract.StateCtlOp) bool {
        return false;
    }
    pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {
        return if (inst.next > t) inst.next else null;
    }
};

const no_paras: SimParas = .{ .names = null, .vals = null, .names_str = null, .vals_str = null };

/// The parameter slot `id` of `d.access` as a `*f64`.
fn real(d: *const Descriptor, ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) *f64 {
    return @ptrCast(@alignCast(d.access(ip, mp, id, flags).?));
}

/// `x` through `eval` at DC, the flags ngspice passes outside a transient.
fn evalAt(d: *const Descriptor, ip: *anyopaque, mp: *anyopaque, x: *const [2]f64) u32 {
    const si: SimInfo = .{ .paras = no_paras, .abstime = 0, .prev_solve = x, .prev_state = null, .next_state = null, .flags = 0 };
    return d.eval(null, ip, mp, &si);
}

test "cName undoes naming.sanitize's escape" {
    try testing.expectEqualStrings("vth", cName("vth"));
    try testing.expectEqualStrings("a_b", cName("aZ5Fb")); // `_` (0x5f) escaped
    try testing.expectEqualStrings("pub", cName("pubZ")); // the keyword marker
    try testing.expectEqualStrings("Z", cName("Z5A")); // a source `Z`
}

test "the descriptor: two terminals, four dense entries, each parameter as instance and model" {
    const H = Osdi(Rc, "rc");
    const d = &H.descriptors[0];
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
    try testing.expectEqual(para_ty_real | para_kind_inst, d.param_opvar[0].flags);
    try testing.expectEqualStrings("$mfactor", std.mem.span(d.param_opvar[2].name[0].?));
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[3].name[0].?));
    try testing.expectEqual(para_ty_real, d.param_opvar[3].flags);
    try testing.expectEqualStrings("a", std.mem.span(d.nodes[0].name.?));
    try testing.expect(!d.nodes[1].is_flow);
    try testing.expectEqual(@as(u32, 0), d.num_noise_src);
    try testing.expectEqual(@as(u32, 0), d.num_collapsible);
}

test "setup, eval and every load: the stamps of a linear RC, and $mfactor over its KCL rows" {
    const H = Osdi(Rc, "rc");
    const d = &H.descriptors[0];
    // ngspice allocates both blobs zeroed and writes parameters through `access`.
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    // The card sets r = 2k (model-side id: after the 3 instance parameters).
    real(d, null, &model, 3, access_flag_set).* = 2e3;
    d.setup_model(null, &model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // `c` was not given: its slot reads back the default.
    try testing.expectEqual(@as(f64, 1e-12), @as(f64, @bitCast(model.vals[1])));
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);

    const g: f64 = 1.0 / 2e3;
    const c: f64 = 1e-12;
    try testing.expectEqual(@as(u32, 0), evalAt(d, &inst, &model, &.{ 1, 0 }));
    var res: [2]f64 = @splat(0);
    d.load_residual_resist(&inst, &model, &res);
    try testing.expectEqualSlices(f64, &.{ g, -g }, &res);
    var react: [2]f64 = @splat(0);
    d.load_residual_react(&inst, &model, &react);
    try testing.expectEqualSlices(f64, &.{ c, -c }, &react);
    // A linear device's SPICE right-hand side J·x − f is 0 at every x.
    var rhs: [2]f64 = @splat(0);
    d.load_spice_rhs_dc(&inst, &model, &rhs, undefined);
    try testing.expectEqualSlices(f64, &.{ 0, 0 }, &rhs);

    var mat: [4]f64 = @splat(0);
    var mat_q: [4]f64 = @splat(0);
    inst.jac_ptr = .{ &mat[0], &mat[1], &mat[2], &mat[3] };
    inst.react_ptr = .{ &mat_q[0], &mat_q[1], &mat_q[2], &mat_q[3] };
    d.load_jacobian_resist(&inst, &model);
    try testing.expectEqualSlices(f64, &.{ g, -g, -g, g }, &mat);
    d.load_jacobian_react(&inst, &model, 2);
    try testing.expectEqualSlices(f64, &.{ 2 * c, -2 * c, -2 * c, 2 * c }, &mat_q);
    var arr: [4]f64 = undefined;
    d.write_jacobian_array_react(&inst, &model, &arr);
    try testing.expectEqualSlices(f64, &.{ c, -c, -c, c }, &arr);

    // §6.3.6: $mfactor = 2 doubles every KCL row, value and Jacobian.
    real(d, &inst, &model, 2, access_flag_set | access_flag_instance).* = 2;
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    _ = evalAt(d, &inst, &model, &.{ 1, 0 });
    try testing.expectEqual(2 * g, inst.res[0]);
    try testing.expectEqual(2 * c, inst.q[0]);
    try testing.expectEqual(-2 * g, inst.jac[1]);
    // An instance's own r overrides the card's; the card keeps its own.
    real(d, &inst, &model, 0, access_flag_set | access_flag_instance).* = 4e3;
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    _ = evalAt(d, &inst, &model, &.{ 1, 0 });
    try testing.expectEqual(@as(f64, 1.0 / 4e3) * 2, inst.res[0]);
    try testing.expectEqual(@as(f64, 2e3), model.card.r);

    try testing.expectEqual(@as(u32, 1), d.given_flag_model(&model, 3)); // r, on the card
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&model, 4)); // c
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&model, 0)); // an instance id
    try testing.expectEqual(@as(u32, 1), d.given_flag_instance(&inst, 0));
    try testing.expectEqual(@as(u32, 1), d.given_flag_instance(&inst, 2)); // $mfactor
    try testing.expectEqual(@as(u32, 0), d.given_flag_instance(&inst, 1));
    // Past the table: no slot, and no given flag.
    try testing.expect(d.access(&inst, &model, 5, 0) == null);
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&model, 5));
}

/// `Rc` with no §3.4 parameter: what VerA emits for a module that declares
/// none (§3.4 makes them optional), `$mfactor` its only OSDI parameter.
const NoParam = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { temperature__: f64 = 300.15 };
    pub const Instance = struct { mfactor: f64 = 1 };

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const i = p[0].sub(p[1]).scale(1e-3);
        return contract.rows(@This(), S, .{ i, i.neg() });
    }
};

test "a module with no parameters builds: $mfactor is the only slot, the model side has none (#79)" {
    const H = Osdi(NoParam, "noparam");
    const d = &H.descriptors[0];
    try testing.expectEqual(@as(u32, 1), d.num_params);
    try testing.expectEqual(@as(u32, 1), d.num_instance_params);
    try testing.expectEqualStrings("$mfactor", std.mem.span(d.param_opvar[0].name[0].?));
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    d.setup_model(null, &model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // Id 0 is $mfactor on the instance; asked of the model, nothing.
    real(d, &inst, &model, 0, access_flag_set | access_flag_instance).* = 2;
    try testing.expect(d.access(null, &model, 0, 0) == null);
    try testing.expect(d.access(null, &model, 1, 0) == null);
    try testing.expectEqual(@as(u32, 0), d.given_flag_model(&model, 0));
    try testing.expectEqual(@as(u32, 1), d.given_flag_instance(&inst, 0));
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // 1 mS between the ports, twice under $mfactor = 2 (§6.3.6).
    _ = evalAt(d, &inst, &model, &.{ 1, 0 });
    try testing.expectEqual(@as(f64, 2e-3), inst.res[0]);
}

test "noise: one source per generator row, its PSD coeff²·white at the last evaluated point" {
    const H = Osdi(Gn, "gn");
    const d = &H.descriptors[0];
    try testing.expectEqual(@as(u32, 1), d.num_noise_src);
    try testing.expectEqual(@as(u32, 0), d.noise_sources.?[0].nodes.node_1);
    try testing.expectEqual(@as(u32, 1), d.noise_sources.?[0].nodes.node_2);
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    _ = evalAt(d, &inst, &model, &.{ 1, 0 });
    var dens: [1]f64 = undefined;
    d.load_noise(&inst, &model, 1e3, &dens);
    try testing.expectEqual(4 * 1.380649e-23 * @as(f64, 300.15) / 1e3, dens[0]);
}

test "a static request is one more iterate (LIM); breakpoints bound the step after each point" {
    const H = Osdi(Ev, "ev");
    const d = &H.descriptors[0];
    try testing.expectEqual(@as(u32, @offsetOf(H.Instance, "bound")), d.bound_step_offset);
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    // DC: the first accepted iterate moved the state, so it is not converged.
    try testing.expectEqual(eval_ret_flag_lim, evalAt(d, &inst, &model, &.{ 1, 0 }));
    try testing.expectEqual(@as(u32, 0), evalAt(d, &inst, &model, &.{ 1, 0 }));
    try testing.expectEqual(std.math.inf(f64), inst.bound);

    const tran = struct {
        fn at(dd: *const Descriptor, ip: *anyopaque, mp: *anyopaque, t: f64) void {
            const x = [2]f64{ 1, 0 };
            const si: SimInfo = .{ .paras = no_paras, .abstime = t, .prev_solve = &x, .prev_state = null, .next_state = null, .flags = analysis_tran | calc_react_residual };
            _ = dd.eval(null, ip, mp, &si);
        }
    };
    // At 1 s the next event is 5 s: the step after is at most 4 s.
    tran.at(d, &inst, &model, 1);
    try testing.expectEqual(@as(f64, 4), inst.bound);
    // At 5 s the event is due and runs only once 5 s is accepted: the step
    // after is held to this one's, 4 s.
    tran.at(d, &inst, &model, 5);
    try testing.expectEqual(@as(f64, 4), inst.bound);
    // At 7 s, 5 s was accepted and scheduled 10 s: the bound is 10 - 7.
    tran.at(d, &inst, &model, 7);
    try testing.expectEqual(@as(f64, 10), inst.inst.next);
    try testing.expectEqual(@as(f64, 3), inst.bound);
}

test "a $simparam list with no NULL within max_sim_paras is refused fatal; one at the cap is read" {
    const H = Osdi(Rc, "rc");
    const d = &H.descriptors[0];
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    // max_sim_paras + 1 names, then the NULL: one past the cap. (Terminated,
    // so the unbounded walk this replaces read it all and set no flag.)
    var names: [max_sim_paras + 2]Str = @splat("x");
    names[max_sim_paras + 1] = null;
    const vals: [max_sim_paras + 1]f64 = @splat(0);
    const long: SimParas = .{ .names = &names, .vals = &vals, .names_str = null, .vals_str = null };
    d.setup_model(null, &model, &long, &info);
    try testing.expectEqual(eval_ret_flag_fatal, info.flags);
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 2, &long, &info);
    try testing.expectEqual(eval_ret_flag_fatal, info.flags);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    const x = [2]f64{ 1, 0 };
    var si: SimInfo = .{ .paras = long, .abstime = 0, .prev_solve = &x, .prev_state = null, .next_state = null, .flags = 0 };
    try testing.expectEqual(eval_ret_flag_fatal, d.eval(null, &inst, &model, &si));
    // The legal neighbour: max_sim_paras names, then the NULL.
    names[max_sim_paras] = null;
    d.setup_model(null, &model, &long, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    d.setup_instance(null, &inst, &model, 300.15, 2, &long, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    si.paras = long;
    try testing.expectEqual(@as(u32, 0), d.eval(null, &inst, &model, &si));
}

test "eqlZ: a host field name matches only whole, and a shorter C string stops at its NUL" {
    try testing.expect(eqlZ("gmin", "gmin"));
    try testing.expect(!eqlZ("gmi", "gmin"));
    try testing.expect(!eqlZ("gminx", "gmin"));
    try testing.expect(!eqlZ("", "gmin"));
}

test "setup_instance refuses more connected terminals than the device has, fatal" {
    const H = Osdi(Rc, "rc");
    const d = &H.descriptors[0];
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    var info: InitInfo = undefined;
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 3, &no_paras, &info);
    try testing.expectEqual(eval_ret_flag_fatal, info.flags);
    // The legal neighbours: every terminal, and fewer (§9.19, the rest internal).
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    d.setup_instance(null, &inst, &model, 300.15, 1, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
}

test "a card value outside a §3.4.2 range is fatal at setup_model and setup_instance (#80)" {
    const H = Osdi(Rc, "rc");
    const d = &H.descriptors[0];
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    // r = -1 on the card (model-side id 3): outside (0:inf).
    real(d, null, &model, 3, access_flag_set).* = -1;
    d.setup_model(null, &model, &no_paras, &info);
    try testing.expectEqual(eval_ret_flag_fatal, info.flags);
    // The legal neighbour: r = 2k on the card.
    real(d, null, &model, 3, access_flag_set).* = 2e3;
    d.setup_model(null, &model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    // An instance's own r is checked too: 0 is outside the open bound.
    real(d, &inst, &model, 0, access_flag_set | access_flag_instance).* = 0;
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(eval_ret_flag_fatal, info.flags);
}

test "a transient time behind the accepted point restarts dt from 0, never negative" {
    const H = Osdi(Rc, "rc");
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    const x = [2]f64{ 0, 0 };
    const at = struct {
        fn dt(i: *H.Instance, xx: *const [2]f64, t: f64) f64 {
            const si: SimInfo = .{ .paras = no_paras, .abstime = t, .prev_solve = xx, .prev_state = null, .next_state = null, .flags = analysis_tran | calc_react_residual };
            return H.simState(i, &si).dt;
        }
    };
    // 1 s then 2 s: steps of 1 s from 0 and from 1 s.
    try testing.expectEqual(@as(f64, 1), at.dt(&inst, &x, 1));
    try testing.expectEqual(@as(f64, 1), at.dt(&inst, &x, 2));
    // A retry at 1.5 s after 2 s is rejected: the step from 1 s.
    try testing.expectEqual(@as(f64, 0.5), at.dt(&inst, &x, 1.5));
    // 0.25 s is behind 1 s, the accepted point (0.25 - 1 = -0.75 before the
    // fix): the history restarts, the step is from 0.
    try testing.expectEqual(@as(f64, 0.25), at.dt(&inst, &x, 0.25));
    // And runs on from there: 0.75 s is a step of 0.5 s from 0.25 s.
    try testing.expectEqual(@as(f64, 0.5), at.dt(&inst, &x, 0.75));
    // A negative time (no transient's) steps 0, not below.
    try testing.expectEqual(@as(f64, 0), at.dt(&inst, &x, -1));
}

test "the module and noise names are the source's, not undone escapes" {
    // `Zener` and `Zth` are legal Verilog-A names. Read as VerA's
    // `Z<hex><hex>` escape, "en" and "th" are no hex pair.
    try testing.expectEqualStrings("Zener", std.mem.span(Osdi(Gn, "Zener").descriptors[0].name.?));
    try testing.expectEqualStrings("Zth", std.mem.span(Osdi(Gn, "gn").descriptors[0].noise_sources.?[0].name.?));
}

test "log: a message past the buffer is cut, not dropped" {
    const Capture = struct {
        var got: [2048]u8 = undefined;
        var len: usize = 0;
        fn f(_: ?*anyopaque, msg: [*:0]const u8, _: u32) callconv(.c) void {
            const s = std.mem.span(msg);
            @memcpy(got[0..s.len], s);
            len = s.len;
        }
    };
    const saved = osdi_log;
    defer osdi_log = saved;
    osdi_log = &Capture.f;
    log(null, log_lvl_err, "short");
    try testing.expectEqualStrings("short\n", Capture.got[0..Capture.len]);
    // 1024 bytes hold 1022 of the message, its newline and the NUL.
    const long: [3000]u8 = @splat('x');
    log(null, log_lvl_err, &long);
    try testing.expectEqual(@as(usize, 1023), Capture.len);
    try testing.expectEqual(@as(u8, '\n'), Capture.got[1022]);
}

/// Two grounded conductances coupled only by a capacitance: (0, 1) and
/// (1, 0) are reactive entries with no resistive part.
const Cg = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct {};
    pub const Instance = struct {};
    pub const jac_pattern = [2]u64{ 0b01, 0b10 };
    pub const q_pattern = [2]u64{ 0b11, 0b11 };

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return .{ S.probe(0, x[0]).scale(2), S.probe(1, x[1]).scale(3) };
    }
    pub fn q(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Sites(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const v = p[0].sub(p[1]).scale(5);
        return contract.sites(@This(), S, .{ v, v.neg() });
    }
    pub fn evalQ(comptime S: type, x: *const [2]S.V, m: *const Model, i: *const Instance, sim: contract.SimState) struct { res: contract.Rows(Cg, S), q: contract.Sites(Cg, S) } {
        return .{ .res = eval(S, x, m, i, sim), .q = q(S, x, m, i, sim) };
    }
};

test "write_jacobian_array_*: one slot per resistive (reactive) entry, in entry order, nothing past them" {
    const H = Osdi(Cg, "cg");
    const d = &H.descriptors[0];
    try testing.expectEqual(@as(u32, 4), d.num_jacobian_entries);
    try testing.expectEqual(@as(u32, 2), d.num_resistive_jacobian_entries);
    try testing.expectEqual(@as(u32, 4), d.num_reactive_jacobian_entries);
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    _ = evalAt(d, &inst, &model, &.{ 1, 0 });
    // OpenVAF's internals.md: an array of num_resistive_jacobian_entries,
    // the entries without JACOBIAN_ENTRY_RESIST left out.
    var arr: [4]f64 = @splat(-1);
    d.write_jacobian_array_resist(&inst, &model, &arr);
    try testing.expectEqualSlices(f64, &.{ 2, 3, -1, -1 }, &arr);
    d.write_jacobian_array_react(&inst, &model, &arr);
    try testing.expectEqualSlices(f64, &.{ 5, -5, -5, 5 }, &arr);
}

/// A conductance with a narrow integer parameter, as VerA emits one.
const Narrow = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { k: u8 = 1 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [2]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const i = p[0].sub(p[1]).scale(@floatFromInt(m.k));
        return contract.rows(@This(), S, .{ i, i.neg() });
    }
};

test "an integer parameter the field cannot hold is fatal, not a trap; the neighbour in range is read" {
    const H = Osdi(Narrow, "narrow");
    const d = &H.descriptors[0];
    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1 };
    var info: InitInfo = undefined;
    const card: *i32 = @ptrCast(@alignCast(d.access(null, &model, 1, access_flag_set).?));
    for ([_]i32{ -1, 256 }) |bad| {
        card.* = bad;
        d.setup_model(null, &model, &no_paras, &info);
        try testing.expectEqual(eval_ret_flag_fatal, info.flags);
    }
    card.* = 255;
    d.setup_model(null, &model, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    const own: *i32 = @ptrCast(@alignCast(d.access(&inst, &model, 0, access_flag_set | access_flag_instance).?));
    own.* = -3;
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(eval_ret_flag_fatal, info.flags);
    own.* = 3;
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    try testing.expectEqual(@as(u8, 3), inst.row.k);
}

/// A resistor `r` from internal node `i` to port `b`, joined to port `a` by
/// series resistance `rs`: a 0 V short when `rs` = 0 (`V(a, i) <+ 0`, flow
/// unknown `f`), as VerA emits PSP's and BSIM's parasitics. `r` is the one
/// parameter marked `type = "instance"`.
const Short = struct {
    pub const U = enum(u8) { a, b, i, f };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const u_kinds = [4]contract.UnknownKind{ .voltage, .voltage, .voltage, .flow };
    pub const Model = struct { rs: f64 = 0, r: f64 = 1e3, temperature__: f64 = 300.15 };
    pub const Instance = struct {};
    pub const instance_params = [_][]const u8{"r"};

    pub fn eval(comptime S: type, x: *const [4]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const ib = p[2].sub(p[1]).scale(1.0 / m.r);
        var a = p[0].scale(0);
        var i = ib;
        var f = p[3];
        if (m.rs != 0) {
            const fl = p[0].sub(p[2]).scale(1.0 / m.rs);
            a = a.add(fl);
            i = i.sub(fl);
        } else if (!(@hasDecl(S, "collapse_applied") and S.collapse_applied)) {
            a = a.add(p[3]);
            i = i.sub(p[3]);
            f = p[0].sub(p[2]);
        }
        return contract.rows(@This(), S, .{ a, ib.neg(), i, f });
    }
    pub fn collapse(comptime _: type, m: *const Model, _: *const Instance) [4]?u8 {
        return if (m.rs == 0) .{ null, null, 0, 0 } else @splat(null);
    }
    pub const collapse_full = [4]?u8{ null, null, 0, 0 };
};

fn evalAt4(d: *const Descriptor, ip: *anyopaque, mp: *anyopaque, x: *const [4]f64) u32 {
    const si: SimInfo = .{ .paras = no_paras, .abstime = 0, .prev_solve = x, .prev_state = null, .next_state = null, .flags = 0 };
    return d.eval(null, ip, mp, &si);
}

test "a 0 V short is a merge pair and its flow collapses into ground; no entry touches the flow" {
    const H = Osdi(Short, "short");
    const d = &H.descriptors[0];
    try testing.expectEqual(@as(u32, 2), d.num_collapsible);
    try testing.expectEqual(NodePair{ .node_1 = 2, .node_2 = 0 }, d.collapsible.?[0]);
    try testing.expectEqual(NodePair{ .node_1 = 3, .node_2 = no_off }, d.collapsible.?[1]);
    for (d.jacobian_entries[0..d.num_jacobian_entries]) |e| {
        try testing.expect(e.nodes.node_1 != 3);
        try testing.expect(e.nodes.node_2 != 3);
    }

    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1, 2, 3 };
    var info: InitInfo = undefined;
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(u32, 0), info.flags);
    const collapsed: [*]const bool = @ptrCast(@as([*]u8, @ptrCast(&inst)) + d.collapsed_offset);
    try testing.expect(collapsed[0] and collapsed[1]);
    // Merged, `i` is `a`: the short's stamps are gone, the resistor's stay.
    _ = evalAt4(d, &inst, &model, &.{ 1, 0, 1, 0 });
    try testing.expectEqualSlices(f64, &.{ 0, -1e-3, 1e-3 }, inst.res[0..3]);

    // A card with rs > 0 keeps both nodes; the flow still drops.
    real(d, null, &model, 1, access_flag_set).* = 50;
    d.setup_model(null, &model, &no_paras, &info);
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expect(!collapsed[0] and collapsed[1]);
    _ = evalAt4(d, &inst, &model, &.{ 1, 0, 0.5, 0 });
    try testing.expectEqualSlices(f64, &.{ 0.5 / 50.0, -0.5e-3, 0.5e-3 - 0.5 / 50.0 }, inst.res[0..3]);
}

test "instance_params: only the marked parameter is an instance parameter; its id asked of the model reads the card" {
    const H = Osdi(Short, "short");
    const d = &H.descriptors[0];
    // `r` on the instance side; `rs` and `r` on the model side.
    try testing.expectEqual(@as(u32, 1), d.num_instance_params);
    try testing.expectEqual(@as(u32, 3), d.num_params);
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[0].name[0].?));
    try testing.expectEqual(para_ty_real | para_kind_inst, d.param_opvar[0].flags);
    try testing.expectEqualStrings("rs", std.mem.span(d.param_opvar[1].name[0].?));
    try testing.expectEqualStrings("r", std.mem.span(d.param_opvar[2].name[0].?));

    var model: H.Model = std.mem.zeroes(H.Model);
    var inst: H.Instance = std.mem.zeroes(H.Instance);
    inst.node_mapping = .{ 0, 1, 2, 3 };
    var info: InitInfo = undefined;
    real(d, null, &model, 2, access_flag_set).* = 2e3; // the card's r
    d.setup_model(null, &model, &no_paras, &info);
    try testing.expectEqual(@as(f64, 2e3), real(d, null, &model, 0, 0).*);
    real(d, &inst, &model, 0, access_flag_set | access_flag_instance).* = 4e3;
    d.setup_instance(null, &inst, &model, 300.15, 2, &no_paras, &info);
    try testing.expectEqual(@as(f64, 4e3), inst.row.r);
    try testing.expectEqual(@as(f64, 2e3), model.card.r);
    // Past the one instance id (no `$mfactor` here), id 1 is the model's `rs`.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&model.vals[0])), d.access(&inst, &model, 1, access_flag_instance));
    try testing.expectEqual(@as(u32, 0), d.given_flag_instance(&inst, 1));
}
