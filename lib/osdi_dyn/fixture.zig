//! Test devices and simulator stand-ins: hand-written contract devices
//! whose every stamp is known exactly (linear ones) or in closed form (the
//! diode), and the calls ngspice's `osdi*.c` make on a descriptor, for the
//! tests in `descriptor.zig` and `eval.zig`. Test support only: nothing
//! outside a `test` block reaches this file.
//!
//! Cites LRM §3.4.2 (`Rc`'s range), §4.6.4 (`Gn`'s thermal generator),
//! §5.6.5 (`Short`'s collapsible branch), §6.3.6 (`$mfactor`), §9.17.3
//! (`Dio`'s limiting and seed), and ngspice-45 `osdiload.c` for the flags
//! `evalDc` and `evalFlags` pass.
//!
//! Contents:
//! - `pub const Rc, Gn, Ev, NoParam, Cg, Narrow, Short, Dio = struct`: contract
//!   devices, each with `U`, `num_ports`, `vera_version`, `Model`, `Instance`
//!   and `eval`, and as its doc says `q`, `evalQ`, `checkRange`,
//!   `noise_gens`, `noisePsd`, `State`, `state_class`, `initState`,
//!   `updateState`, `stateCtl`, `pendingBreakpoint`, `jac_pattern`,
//!   `q_pattern`, `u_kinds`, `instance_params`, `collapse`, `collapse_full`,
//!   `limit`, `seed`, `v_max`, `v_seed`
//! - `pub const DioBench = struct`, with `d`, `init`, `residual`, `jacobian`
//! - `pub const no_paras: abi.SimParas`
//! - `pub fn real(d: *const abi.Descriptor, ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) *f64`
//! - `pub fn evalDc(d: *const abi.Descriptor, ip: *anyopaque, mp: *anyopaque, x: []const f64) u32`
//! - `pub fn evalFlags(d: *const abi.Descriptor, ip: *anyopaque, mp: *anyopaque, x: []const f64, t: f64, flags: u32) u32`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const abi = @import("abi.zig");
const blobs = @import("blobs.zig");
const descriptor = @import("descriptor.zig");

/// A conductance 1/r in parallel with a capacitance c between two ports, plus
/// `$mfactor`: every resistive and reactive path, and an instance parameter
/// over the card.
pub const Rc = struct {
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
pub const Gn = struct {
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
pub const Ev = struct {
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

/// `Rc` with no §3.4 parameter: what VerA emits for a module that declares
/// none (§3.4 makes them optional), `$mfactor` its only OSDI parameter.
pub const NoParam = struct {
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

/// Two grounded conductances coupled only by a capacitance: (0, 1) and
/// (1, 0) are reactive entries with no resistive part.
pub const Cg = struct {
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

/// A conductance with a narrow integer parameter, as VerA emits one.
pub const Narrow = struct {
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

/// A resistor `r` from internal node `i` to port `b`, joined to port `a` by
/// series resistance `rs`: a 0 V short when `rs` = 0 (`V(a, i) <+ 0`, flow
/// unknown `f`), as VerA emits PSP's and BSIM's parasitics. `r` is the one
/// parameter marked `type = "instance"`.
pub const Short = struct {
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

/// An exponential junction `is·(exp(V(a, b)/vt) − 1)` from `a` to `b`, plus
/// a 1 mS leak to ground on `b`, with SPICE-style limiting (a clamp of
/// V(a, b) at `v_max`, never converged when it bites) and a seed of 0.6 V on
/// `a`: a nonlinear device whose limited RHS and Jacobian have closed forms.
pub const Dio = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { is: f64 = 1e-14, vt: f64 = 0.025 };
    pub const Instance = struct {};
    /// The clamp `limit` applies to V(a, b).
    pub const v_max: f64 = 0.7;
    /// The seed `seed` puts on `a`.
    pub const v_seed: f64 = 0.6;

    pub fn eval(comptime S: type, x: *const [2]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const i = p[0].sub(p[1]).scale(1.0 / m.vt).exp().addC(-1).scale(m.is);
        return contract.rows(@This(), S, .{ i, i.neg().add(p[1].scale(1e-3)) });
    }
    pub fn limit(comptime _: type, _: *const Model, _: *const Instance, cur: [2]f64, _: [2]f64, _: contract.SimState) contract.LimitResult(2) {
        if (cur[0] - cur[1] <= v_max) return .{ .x = cur, .converged = true };
        return .{ .x = .{ cur[1] + v_max, cur[1] }, .converged = false };
    }
    pub fn seed(comptime _: type, _: *const Model, _: *const Instance, _: contract.SimState) [2]?f64 {
        return .{ v_seed, null };
    }
};

/// `Dio` set up on a zeroed pair of blobs, its nodes mapped to 0 and 1.
pub const DioBench = struct {
    model: blobs.Model(Dio),
    inst: blobs.Instance(Dio),

    pub const d = &descriptor.Library(Dio, "dio", false).descriptors[0];

    pub fn init(b: *DioBench) error{TestExpectedEqual}!void {
        b.model = std.mem.zeroes(blobs.Model(Dio));
        b.inst = std.mem.zeroes(blobs.Instance(Dio));
        b.inst.node_mapping = .{ 0, 1 };
        var info: abi.InitInfo = undefined;
        d.setup_model(null, &b.model, &no_paras, &info);
        try std.testing.expectEqual(@as(u32, 0), info.flags);
        d.setup_instance(null, &b.inst, &b.model, 300.15, 2, &no_paras, &info);
        try std.testing.expectEqual(@as(u32, 0), info.flags);
    }

    /// The resistive residual at `x`, unlimited, as `load_residual_resist` adds it.
    pub fn residual(b: *DioBench, x: [2]f64) [2]f64 {
        _ = evalDc(d, &b.inst, &b.model, &x);
        var r: [2]f64 = @splat(0);
        d.load_residual_resist(&b.inst, &b.model, &r);
        return r;
    }

    /// The resistive Jacobian, row-major, as `load_jacobian_resist` adds it.
    pub fn jacobian(b: *DioBench) [4]f64 {
        var mat: [4]f64 = @splat(0);
        b.inst.jac_ptr = .{ &mat[0], &mat[1], &mat[2], &mat[3] };
        d.load_jacobian_resist(&b.inst, &b.model);
        b.inst.jac_ptr = @splat(null);
        return mat;
    }
};

/// No `$simparam` list: what a simulator passes that sets none.
pub const no_paras: abi.SimParas = .{ .names = null, .vals = null, .names_str = null, .vals_str = null };

/// The parameter slot `id` of `d.access` as a `*f64`. Asserts that the
/// slot exists.
pub fn real(d: *const abi.Descriptor, ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) *f64 {
    assert(id < d.num_params);
    const p = d.access(ip, mp, id, flags).?;
    return @ptrCast(@alignCast(p));
}

/// `eval` at `x` (the node values, node `k` at index `k`) with the flags
/// ngspice passes outside a transient (none). Returns `eval`'s flags.
pub fn evalDc(d: *const abi.Descriptor, ip: *anyopaque, mp: *anyopaque, x: []const f64) u32 {
    return evalFlags(d, ip, mp, x, 0, 0);
}

/// `eval` at `x`, time `t` and `flags`. Returns `eval`'s flags. Asserts
/// that `x` holds a value per node.
pub fn evalFlags(d: *const abi.Descriptor, ip: *anyopaque, mp: *anyopaque, x: []const f64, t: f64, flags: u32) u32 {
    assert(x.len == d.num_nodes);
    const si: abi.SimInfo = .{ .paras = no_paras, .abstime = t, .prev_solve = x.ptr, .prev_state = null, .next_state = null, .flags = flags };
    const ret = d.eval(null, ip, mp, &si);
    assert(ret & ~(abi.eval_ret_flag_lim | abi.eval_ret_flag_fatal) == 0);
    return ret;
}
