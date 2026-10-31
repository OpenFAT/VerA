//! OSDI 0.4's C interface as Zig declarations: `osdi_0_4.h` in, the extern
//! structs, flag words and exported version words a simulator reads out,
//! plus the `osdi_log` slot it writes and `log`, the one way this library
//! talks back through it.
//!
//! Cites OpenVAF-Reloaded `openvaf/osdi/header/osdi_0_4.h` at fdf2522b70f4
//! (every layout and constant here) and ngspice-45 `src/osdi/`, which reads
//! the 0.3 prefix of `Descriptor` and steps through its arrays by the C
//! sizes asserted below. No LRM clause.
//!
//! Contents:
//! - `pub const Str = ?[*:0]const u8`
//! - `pub const no_off: u32`
//! - `pub const para_ty_real, para_ty_int, para_ty_str, para_kind_inst: u32`
//! - `pub const access_flag_set, access_flag_instance: u32`
//! - `pub const jacobian_entry_resist, jacobian_entry_react: u32`
//! - `pub const calc_react_residual, enable_lim, init_lim, analysis_noise, analysis_ac, analysis_tran: u32`
//! - `pub const eval_ret_flag_lim, eval_ret_flag_fatal: u32`
//! - `pub const log_lvl_warn, log_lvl_err, log_lvl_fatal: u32`
//! - `pub const SimParas, SimInfo, InitError, InitInfo, NodePair, JacobianEntry, Node, ParamOpvar, NoiseSource, NatureRef, AbsDelayInfo, Descriptor = extern struct`
//! - `pub const osdi_version_major, osdi_version_minor, osdi_num_descriptors, osdi_descriptor_size: u32`
//! - `pub var osdi_log: ?*const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) void`
//! - `pub const log_line_max: usize`
//! - `pub fn log(handle: ?*anyopaque, lvl: u32, msg: []const u8) void`

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// A C string the descriptor points at, or NULL.
pub const Str = ?[*:0]const u8;

/// `UINT32_MAX`: an offset the instance does not have (a node with no
/// reactive residual, an entry with no reactive pointer), or ground as the
/// second node of a pair.
pub const no_off: u32 = std.math.maxInt(u32);

/// `PARA_TY_*`: a parameter's C type, the low bits of `ParamOpvar.flags`.
pub const para_ty_real: u32 = 0;
/// `PARA_TY_INT`: `int32_t`.
pub const para_ty_int: u32 = 1;
/// `PARA_TY_STR`: `char *`.
pub const para_ty_str: u32 = 2;
/// `PARA_KIND_INST`: the parameter is an instance parameter.
pub const para_kind_inst: u32 = 1 << 30;

/// `ACCESS_FLAG_SET`: the simulator will write through the pointer.
pub const access_flag_set: u32 = 1;
/// `ACCESS_FLAG_INSTANCE`: the instance's slot, not the model's.
pub const access_flag_instance: u32 = 4;

/// `JACOBIAN_ENTRY_RESIST`: the entry has a resistive part.
pub const jacobian_entry_resist: u32 = 4;
/// `JACOBIAN_ENTRY_REACT`: the entry has a reactive part.
pub const jacobian_entry_react: u32 = 8;

/// `CALC_REACT_RESIDUAL`: the simulator wants the reactive residual (ngspice
/// sets it in a transient's time steps).
pub const calc_react_residual: u32 = 2;
/// `ENABLE_LIM`: limit against the previous iterate.
pub const enable_lim: u32 = 256;
/// `INIT_LIM`: seed the iterate (SPICE `MODEINITJCT`).
pub const init_lim: u32 = 512;
/// `ANALYSIS_NOISE`.
pub const analysis_noise: u32 = 1024;
/// `ANALYSIS_AC`.
pub const analysis_ac: u32 = 4096;
/// `ANALYSIS_TRAN`.
pub const analysis_tran: u32 = 8192;

/// `EVAL_RET_FLAG_LIM`: this iterate is not converged.
pub const eval_ret_flag_lim: u32 = 1;
/// `EVAL_RET_FLAG_FATAL`: stop the simulation.
pub const eval_ret_flag_fatal: u32 = 2;

/// `LOG_LVL_WARN`.
pub const log_lvl_warn: u32 = 3;
/// `LOG_LVL_ERR`.
pub const log_lvl_err: u32 = 4;
/// `LOG_LVL_FATAL`.
pub const log_lvl_fatal: u32 = 5;

/// `OsdiSimParas`: the simulator's `$simparam` names and values, each list
/// NULL-terminated and uncounted.
pub const SimParas = extern struct {
    names: ?[*]const Str,
    vals: ?[*]const f64,
    names_str: ?[*]const Str,
    vals_str: ?[*]const Str,
};

/// `OsdiSimInfo`: what `eval` is asked to evaluate.
pub const SimInfo = extern struct {
    paras: SimParas,
    abstime: f64,
    prev_solve: [*]const f64,
    prev_state: ?[*]f64,
    next_state: ?[*]f64,
    flags: u32,
};

/// `OsdiInitError`.
pub const InitError = extern struct { code: u32, parameter_id: u32 };
/// `OsdiInitInfo`: `setup_model`'s and `setup_instance`'s result.
pub const InitInfo = extern struct { flags: u32, num_errors: u32, errors: ?*InitError };
/// `OsdiNodePair`.
pub const NodePair = extern struct { node_1: u32, node_2: u32 };
/// `OsdiJacobianEntry`.
pub const JacobianEntry = extern struct { nodes: NodePair, react_ptr_off: u32, flags: u32 };

/// `OsdiNode`: one unknown, and where its residuals sit in the instance.
pub const Node = extern struct {
    name: Str,
    units: Str,
    residual_units: Str,
    resist_residual_off: u32,
    react_residual_off: u32,
    resist_limit_rhs_off: u32,
    react_limit_rhs_off: u32,
    is_flow: bool,
};

/// `OsdiParamOpvar`: one parameter (or operating-point variable).
pub const ParamOpvar = extern struct {
    name: [*]const Str,
    num_alias: u32,
    description: Str,
    units: Str,
    flags: u32,
    len: u32,
};

/// `OsdiNoiseSource`.
pub const NoiseSource = extern struct { name: Str, nodes: NodePair };
/// `OsdiNatureRef`.
pub const NatureRef = extern struct { ref_type: u32, index: u32 };
/// `OsdiAbsDelayInfo`.
pub const AbsDelayInfo = extern struct {
    input_node_1: u32,
    input_node_2: u32,
    output_node: u32,
    delay_offset: u32,
    max_delay_offset: u32,
};

/// `OsdiDescriptor`, 0.4: the 0.3 prefix ngspice-45 reads, then the 0.4
/// additions.
pub const Descriptor = extern struct {
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

/// `OSDI_VERSION_MAJOR`.
pub const osdi_version_major: u32 = 0;
/// `OSDI_VERSION_MINOR`.
pub const osdi_version_minor: u32 = 4;
/// `OSDI_NUM_DESCRIPTORS`: one device per library.
pub const osdi_num_descriptors: u32 = 1;
/// `OSDI_DESCRIPTOR_SIZE`: the stride a simulator steps `OSDI_DESCRIPTORS` by.
pub const osdi_descriptor_size: u32 = @sizeOf(Descriptor);

/// `osdi_log`: the simulator writes its logger here when it loads the
/// library (ngspice's INIT_CALLBACK). Mutable because the ABI says so; only
/// the simulator (and a test) writes it.
pub var osdi_log: ?*const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) void = null;

/// The longest message `log` hands the logger, its newline and NUL
/// included; a longer one is cut to fit.
pub const log_line_max: usize = 1024;

comptime {
    // osdi_0_4.h's flag words: each flag one bit, and the flags that share a
    // word disjoint (their OR is their sum), so `flags & f` tests one flag.
    for ([_]u32{
        access_flag_set,     access_flag_instance, jacobian_entry_resist, jacobian_entry_react,
        calc_react_residual, enable_lim,           init_lim,              analysis_noise,
        analysis_ac,         analysis_tran,        eval_ret_flag_lim,     eval_ret_flag_fatal,
        para_kind_inst,
    }) |f| assert(std.math.isPowerOfTwo(f));
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
    // A message, its newline and its NUL.
    assert(log_line_max > 2);
    // The C sizes osdi_0_4.h's structs have on a 64-bit target: ngspice
    // steps through the descriptor's arrays by them.
    if (@sizeOf(usize) == 8) {
        assert(@sizeOf(NodePair) == 8);
        assert(@sizeOf(JacobianEntry) == 16);
        assert(@sizeOf(InitError) == 8);
        assert(@sizeOf(InitInfo) == 16);
        assert(@sizeOf(NoiseSource) == 16);
        assert(@sizeOf(SimParas) == 32);
        assert(@sizeOf(SimInfo) == 72);
        assert(@sizeOf(Node) == 48);
        assert(@sizeOf(ParamOpvar) == 40);
    }
}

/// Sends `msg` and a newline to the simulator's logger at level `lvl`; does
/// nothing before the simulator installed one. A message longer than
/// `log_line_max - 2` bytes is cut to that, not dropped: a fatal status
/// names its file and line first. Asserts that `lvl` is a `log_lvl_*`.
pub fn log(handle: ?*anyopaque, lvl: u32, msg: []const u8) void {
    assert(lvl >= log_lvl_warn);
    assert(lvl <= log_lvl_fatal);
    // Through the exported symbol: a split build's `.eval` object has its
    // own copy of `osdi_log`, which the simulator never writes.
    const slot = if (builtin.is_test) &osdi_log else @extern(*const @TypeOf(osdi_log), .{ .name = "osdi_log" });
    const f = slot.* orelse return;
    var buf: [log_line_max]u8 = undefined;
    const cut = msg[0..@min(msg.len, buf.len - 2)];
    // `cut`, its newline and the NUL fit `buf` by the bound above.
    const z = std.mem.printSentinel(&buf, "{s}\n", .{cut}, 0) catch unreachable;
    assert(z.len == cut.len + 1);
    assert(z.len < buf.len);
    f(handle, z.ptr, lvl);
}

// ---- private ----

test "log: a message past the buffer is cut, not dropped" {
    const Capture = struct {
        var got: [2 * log_line_max]u8 = undefined;
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
    try std.testing.expectEqualStrings("short\n", Capture.got[0..Capture.len]);
    // 1024 bytes hold 1022 of the message, its newline and the NUL.
    const long: [3000]u8 = @splat('x');
    log(null, log_lvl_err, &long);
    try std.testing.expectEqual(@as(usize, 1023), Capture.len);
    try std.testing.expectEqual(@as(u8, '\n'), Capture.got[1022]);
}
